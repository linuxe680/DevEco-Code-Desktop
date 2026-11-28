import Foundation

/// Reasoning is emitted once per model step, but users read it as one thought
/// for the whole turn. A group is anchored at the first step of a consecutive
/// assistant run and shared by every member.
struct ThinkingGroup {
    let anchorID: String
    let text: String
}

struct ToolRunGroup {
    let anchorID: String
    let parts: [Part]
}

/// One transcript row: the message plus the decorations derived from its
/// neighbours (day divider, merged reasoning, grouped tool runs, model-change
/// notice).
struct MessageRow {
    let message: MessageRecord
    var thinking: ThinkingGroup?
    var tools: ToolRunGroup?
    let isDateDivider: Bool
    let modelChangeNotice: String?
}

/// Everything a row derives from its neighbours. Deliberately holds no
/// `MessageRecord`: the cache keeps these for the sealed prefix, and every
/// call pairs them with the caller's current messages. That way a late
/// `message.updated` (usage, cost, model) or a tool output that lands after
/// the message stopped being the tail can never render stale content.
private struct RowDecoration {
    var thinking: ThinkingGroup?
    var tools: ToolRunGroup?
    var isDateDivider = false
    var modelChangeNotice: String?
}

/// Derives transcript rows incrementally.
///
/// Before this cache every `body` evaluation walked the whole transcript and
/// joined the reasoning text of every consecutive assistant run. During
/// streaming `body` runs ~30×/s, so a 500-message session paid that cost
/// continuously even though only the last message was changing.
///
/// The transcript only changes at its tail while a reply streams, so all
/// messages except the last are folded into a checkpoint once. Each call
/// re-folds just the tail on a copy of that checkpoint. A cheap fingerprint
/// over the sealed prefix (ids, roles, timestamps, part types, text lengths —
/// no string copies) tells us when that checkpoint went stale, so a revert,
/// late tool update or reload still rebuilds correctly.
final class TranscriptRowCache {
    private struct ThinkingRun {
        var anchorID: String
        var memberIDs: [String] = []
        var rowIndices: [Int] = []
        var texts: [String] = []
    }

    private struct ToolRun {
        var anchorID: String
        var memberIDs: [String] = []
        var rowIndices: [Int] = []
        var parts: [Part] = []
    }

    private struct FoldState {
        var decorations: [RowDecoration] = []
        var lastDay: Date?
        var thinking: ThinkingRun?
        var tool: ToolRun?
        var foldedCount = 0
    }

    private var checkpoint = FoldState()
    private var checkpointSignature: UInt64 = 0

    /// Whole-result memo. `SessionStore.transcriptRevision` bumps on every
    /// transcript mutation, so an unchanged revision with an unchanged count
    /// means the same rows — no fold, no assembly. Saves the work `body`
    /// repeats for unrelated `@Published` churn (`isSending`, drafts, …).
    private var memoRevision = Int.min
    private var memoCount = -1
    private var memoRows: [MessageRow] = []

    /// Search results, memoized per (revision, count, query).
    private var searchRevision = Int.min
    private var searchCount = -1
    private var searchQuery = ""
    private var searchResult: [MessageRecord] = []

    // MARK: Rows

    /// - Parameter revision: the owner's transcript revision. Must change
    ///   whenever `messages` does, which `SessionStore.messages` guarantees.
    /// - Parameter decorations: when false (⌘F search), reasoning/tool groups
    ///   and model-change notices are omitted, matching the previous
    ///   search-mode rendering.
    func rows(for messages: [MessageRecord], revision: Int, decorations: Bool = true) -> [MessageRow] {
        guard decorations else {
            // Search results are a filtered subset of the transcript, so they
            // can share neither the checkpoint nor the revision memo: two
            // different queries can match the same number of messages. The
            // fold is linear and the match list itself is already memoized.
            var state = FoldState()
            for message in messages { fold(message, into: &state, decorations: false) }
            closeRuns(&state)
            return assemble(messages, state)
        }

        if revision == memoRevision, messages.count == memoCount {
            return memoRows
        }

        let state = decoratedState(for: messages)
        let rows = assemble(messages, state)
        memoRevision = revision
        memoCount = messages.count
        memoRows = rows
        return rows
    }

    /// Folds the sealed prefix into the checkpoint when its fingerprint
    /// changed, then re-folds the tail (normally a single message) on a copy.
    private func decoratedState(for messages: [MessageRecord]) -> FoldState {
        // The last message is the only one a stream mutates; everything
        // before it is sealed.
        let sealedCount = max(0, messages.count - 1)
        let signature = Self.signature(of: messages, count: sealedCount)
        if signature != checkpointSignature || checkpoint.foldedCount != sealedCount {
            var state = FoldState()
            for index in 0..<sealedCount { fold(messages[index], into: &state) }
            checkpoint = state
            checkpointSignature = signature
        }

        var tail = checkpoint
        for index in sealedCount..<messages.count { fold(messages[index], into: &tail) }
        closeRuns(&tail)
        return tail
    }

    /// Pairs decorations with the caller's current messages. Reading a
    /// checkpoint array here shares it (copy-on-write) instead of copying.
    private func assemble(_ messages: [MessageRecord], _ state: FoldState) -> [MessageRow] {
        messages.indices.map { index in
            let decoration = state.decorations[index]
            return MessageRow(
                message: messages[index],
                thinking: decoration.thinking,
                tools: decoration.tools,
                isDateDivider: decoration.isDateDivider,
                modelChangeNotice: decoration.modelChangeNotice
            )
        }
    }

    // MARK: Search

    func matches(in messages: [MessageRecord], query: String, revision: Int) -> [MessageRecord] {
        if revision == searchRevision, messages.count == searchCount, query == searchQuery {
            return searchResult
        }
        let result = messages.filter { message in
            message.parts.contains {
                ($0.text ?? "").localizedCaseInsensitiveContains(query)
            }
        }
        searchRevision = revision
        searchCount = messages.count
        searchQuery = query
        searchResult = result
        return result
    }

    // MARK: Fingerprint

    /// O(parts) fingerprint of the sealed prefix: no string copies, no
    /// allocations. Covers every input the decorations read — appends,
    /// new/removed parts, edits (text length), tool status/title/output/error
    /// lengths and tool timing. Rewriting a sealed string with one of the
    /// same length is the one edit it cannot see; the next structural change
    /// rebuilds the prefix, so it self-heals.
    static func signature(of messages: [MessageRecord], count: Int) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(count)
        for index in 0..<count {
            let message = messages[index]
            hasher.combine(message.info.id)
            hasher.combine(message.info.role)
            hasher.combine(message.info.createdDate?.timeIntervalSince1970)
            hasher.combine(message.parts.count)
            for part in message.parts {
                hasher.combine(part.id)
                hasher.combine(part.type)
                hasher.combine(part.text?.utf8.count)
                hasher.combine(part.tool)
                hasher.combine(part.state?.status)
                hasher.combine(part.state?.title?.utf8.count)
                hasher.combine(part.state?.output?.utf8.count)
                hasher.combine(part.state?.error?.utf8.count)
                hasher.combine(part.state?.time?.start)
                hasher.combine(part.state?.time?.end)
            }
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    // MARK: Folding

    private func fold(_ message: MessageRecord, into state: inout FoldState, decorations: Bool = true) {
        // A non-assistant message ends any open run before this row.
        if message.info.role != "assistant" {
            closeThinking(&state)
            closeTool(&state)
        }

        let day = message.info.createdDate.map { Calendar.current.startOfDay(for: $0) }
        let showDay = day != nil && day != state.lastDay
        state.lastDay = day

        let notice = decorations
            ? message.parts
                .compactMap(\.text)
                .first(where: isModelChangeNotice)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        let rowIndex = state.decorations.count
        state.decorations.append(
            RowDecoration(thinking: nil, tools: nil, isDateDivider: showDay, modelChangeNotice: notice)
        )
        state.foldedCount += 1

        guard decorations, message.info.role == "assistant" else { return }

        if state.thinking == nil { state.thinking = ThinkingRun(anchorID: message.id) }
        state.thinking?.memberIDs.append(message.id)
        state.thinking?.rowIndices.append(rowIndex)
        for part in message.parts where part.type == "reasoning" {
            guard let text = part.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            state.thinking?.texts.append(text)
        }

        if state.tool == nil { state.tool = ToolRun(anchorID: message.id) }
        state.tool?.memberIDs.append(message.id)
        state.tool?.rowIndices.append(rowIndex)
        state.tool?.parts.append(contentsOf: message.parts.filter { $0.type == "tool" })
    }

    private func closeRuns(_ state: inout FoldState) {
        closeThinking(&state)
        closeTool(&state)
    }

    private func closeThinking(_ state: inout FoldState) {
        guard let run = state.thinking else { return }
        state.thinking = nil
        guard !run.texts.isEmpty else { return }
        let group = ThinkingGroup(anchorID: run.anchorID, text: run.texts.joined(separator: "\n\n"))
        for index in run.rowIndices {
            state.decorations[index].thinking = group
        }
    }

    private func closeTool(_ state: inout FoldState) {
        guard let run = state.tool else { return }
        state.tool = nil
        guard run.parts.count > 1 else { return }
        let group = ToolRunGroup(anchorID: run.anchorID, parts: run.parts)
        for index in run.rowIndices {
            state.decorations[index].tools = group
        }
    }
}
