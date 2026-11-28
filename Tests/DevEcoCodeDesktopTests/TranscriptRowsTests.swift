import XCTest
@testable import DevEcoCodeDesktop

/// The incremental transcript-row cache must produce exactly the rows the old
/// full-walk implementation did, while rebuilding only what changed.
final class TranscriptRowsTests: XCTestCase {
    // MARK: Reference implementation (the previous full-walk logic)

    private func referenceRows(_ messages: [MessageRecord]) -> [MessageRow] {
        var thinking: [String: ThinkingGroup] = [:]
        var toolRuns: [String: ToolRunGroup] = [:]

        var anchorID: String?
        var memberIDs: [String] = []
        var texts: [String] = []
        func flushThinking() {
            defer {
                anchorID = nil
                memberIDs = []
                texts = []
            }
            guard let anchorID, !texts.isEmpty else { return }
            let group = ThinkingGroup(anchorID: anchorID, text: texts.joined(separator: "\n\n"))
            for id in memberIDs { thinking[id] = group }
        }

        var toolAnchor: String?
        var toolMembers: [String] = []
        var toolParts: [Part] = []
        func flushTools() {
            defer {
                toolAnchor = nil
                toolMembers = []
                toolParts = []
            }
            guard let toolAnchor, toolParts.count > 1 else { return }
            let group = ToolRunGroup(anchorID: toolAnchor, parts: toolParts)
            for id in toolMembers { toolRuns[id] = group }
        }

        for message in messages {
            guard message.info.role == "assistant" else {
                flushThinking()
                flushTools()
                continue
            }
            if anchorID == nil { anchorID = message.id }
            memberIDs.append(message.id)
            for part in message.parts where part.type == "reasoning" {
                guard let text = part.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                texts.append(text)
            }
            if toolAnchor == nil { toolAnchor = message.id }
            toolMembers.append(message.id)
            toolParts.append(contentsOf: message.parts.filter { $0.type == "tool" })
        }
        flushThinking()
        flushTools()

        var lastDay: Date?
        return messages.map { message in
            let notice = message.parts
                .compactMap(\.text)
                .first(where: isModelChangeNotice)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let day = message.info.createdDate.map { Calendar.current.startOfDay(for: $0) }
            let showDay = day != nil && day != lastDay
            lastDay = day
            return MessageRow(
                message: message,
                thinking: thinking[message.id],
                tools: toolRuns[message.id],
                isDateDivider: showDay,
                modelChangeNotice: notice
            )
        }
    }

    private func assertEquivalent(_ messages: [MessageRecord], file: StaticString = #filePath, line: UInt = #line) {
        let cache = TranscriptRowCache()
        let actual = cache.rows(for: messages, revision: 0)
        let expected = referenceRows(messages)
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (lhs, rhs) in zip(actual, expected) {
            XCTAssertEqual(lhs.message.id, rhs.message.id, file: file, line: line)
            XCTAssertEqual(lhs.isDateDivider, rhs.isDateDivider, file: file, line: line)
            XCTAssertEqual(lhs.modelChangeNotice, rhs.modelChangeNotice, file: file, line: line)
            XCTAssertEqual(lhs.thinking?.anchorID, rhs.thinking?.anchorID, file: file, line: line)
            XCTAssertEqual(lhs.thinking?.text, rhs.thinking?.text, file: file, line: line)
            XCTAssertEqual(lhs.tools?.anchorID, rhs.tools?.anchorID, file: file, line: line)
            XCTAssertEqual(lhs.tools?.parts.map(\.id), rhs.tools?.parts.map(\.id), file: file, line: line)
        }
    }

    // MARK: Fixtures

    private func assistant(
        _ id: String,
        reasoning: [String] = [],
        tools: [String] = [],
        text: String? = nil,
        createdAt: Double? = nil
    ) -> MessageRecord {
        var parts: [Part] = []
        for (index, value) in reasoning.enumerated() {
            parts.append(Part(id: "\(id)_r\(index)", type: "reasoning", text: value))
        }
        for (index, value) in tools.enumerated() {
            parts.append(Part(id: "\(id)_t\(index)", type: "tool", tool: value,
                              state: ToolState(status: "completed")))
        }
        if let text {
            parts.append(Part(id: "\(id)_x", type: "text", text: text))
        }
        return MessageRecord(
            info: MessageInfo(id: id, role: "assistant", modelID: "m", providerID: "p",
                              time: createdAt.map { MessageTime(created: $0, completed: nil) }),
            parts: parts
        )
    }

    private func user(_ id: String, _ text: String, createdAt: Double? = nil) -> MessageRecord {
        MessageRecord(
            info: MessageInfo(id: id, role: "user",
                              time: createdAt.map { MessageTime(created: $0, completed: nil) }),
            parts: [Part(id: "\(id)_p", type: "text", text: text)]
        )
    }

    // MARK: Tests

    func testEmptyTranscript() {
        assertEquivalent([])
    }

    func testSingleUserMessage() {
        assertEquivalent([user("u1", "hello")])
    }

    func testMergesConsecutiveAssistantReasoning() {
        let messages = [
            user("u1", "go"),
            assistant("a1", reasoning: ["first thought"], tools: ["read"]),
            assistant("a2", reasoning: ["second thought"], tools: ["edit"]),
            user("u2", "again"),
            assistant("a3", reasoning: ["fresh thought"]),
        ]
        assertEquivalent(messages)
    }

    func testSingleToolIsNotGrouped() {
        // The old code only created a run when more than one tool part existed.
        assertEquivalent([
            user("u1", "go"),
            assistant("a1", tools: ["read"]),
        ])
    }

    func testDayDividers() {
        let dayOne = 1_700_000_000_000.0
        let dayTwo = dayOne + 86_400_000
        assertEquivalent([
            user("u1", "one", createdAt: dayOne),
            assistant("a1", text: "reply", createdAt: dayOne + 1000),
            user("u2", "two", createdAt: dayTwo),
        ])
    }

    func testModelChangeNoticeIsExtracted() {
        assertEquivalent([
            assistant("a1", text: "模型已从 A 更改为 B。"),
            assistant("a2", text: "正文"),
        ])
    }

    func testStreamingTailOnlyChangesLastRow() {
        let cache = TranscriptRowCache()
        var messages: [MessageRecord] = []
        for index in 0..<200 {
            messages.append(user("u\(index)", "prompt \(index)"))
            messages.append(assistant("a\(index)", reasoning: ["thinking \(index)"], text: "answer \(index)"))
        }
        let sealed = cache.rows(for: messages, revision: 0)
        XCTAssertEqual(sealed.count, messages.count)

        // Append to the final text part: the shape of a streamed delta.
        var streamed = messages
        let lastPartIndex = streamed[streamed.count - 1].parts.count - 1
        streamed[streamed.count - 1].parts[lastPartIndex].text = "answer 199 plus more"
        let updated = cache.rows(for: streamed, revision: 1)

        XCTAssertEqual(updated.count, streamed.count)
        for index in 0..<(updated.count - 1) {
            XCTAssertEqual(updated[index].message.id, sealed[index].message.id)
            XCTAssertEqual(updated[index].thinking?.text, sealed[index].thinking?.text)
        }
        XCTAssertEqual(updated.last?.message.parts.last?.text, "answer 199 plus more")
    }

    func testSealedPrefixEditInvalidatesCheckpoint() {
        let cache = TranscriptRowCache()
        let first = [
            user("u1", "go"),
            assistant("a1", reasoning: ["early"], text: "x"),
            user("u2", "next"),
            assistant("a2", text: "y"),
        ]
        _ = cache.rows(for: first, revision: 0)

        // A revert/reload rewrites an earlier message; the cache must notice.
        var edited = first
        edited[1].parts[0].text = "rewritten reasoning"
        assertEquivalentCache(cache, edited, revision: 1)
    }

    func testMessageRemovalInvalidatesCheckpoint() {
        let cache = TranscriptRowCache()
        var messages = [
            user("u1", "go"),
            assistant("a1", reasoning: ["early"]),
            assistant("a2", reasoning: ["late"]),
            user("u2", "next"),
        ]
        _ = cache.rows(for: messages, revision: 0)
        messages.remove(at: 1)
        assertEquivalentCache(cache, messages, revision: 1)
    }

    func testSearchResultsAreMemoizedAndCorrect() {
        let cache = TranscriptRowCache()
        let messages = [
            user("u1", "alpha beta"),
            assistant("a1", text: "nothing here"),
            user("u2", "beta again"),
        ]
        let matches = cache.matches(in: messages, query: "beta", revision: 0)
        XCTAssertEqual(matches.map(\.id), ["u1", "u2"])
        // Same revision + query returns the memoized array without rescanning.
        XCTAssertEqual(cache.matches(in: messages, query: "beta", revision: 0).map(\.id), ["u1", "u2"])
        // A new revision invalidates.
        XCTAssertEqual(cache.matches(in: messages, query: "alpha", revision: 1).map(\.id), ["u1"])
    }

    /// A sealed message can still change after it stops being the tail:
    /// `message.updated` lands usage/cost/model once the turn finishes, and a
    /// tool part's output can arrive late. The cache stores only decorations,
    /// so rows always carry the caller's current message.
    func testLateUpdateToSealedMessageIsVisible() {
        let cache = TranscriptRowCache()
        var messages = [
            user("u1", "go"),
            assistant("a1", tools: ["read"], text: "done"),
            user("u2", "next"),
            assistant("a2", text: "tail"),
        ]
        _ = cache.rows(for: messages, revision: 0)

        // Late tool output plus usage on the sealed assistant message.
        messages[1].parts[0] = Part(id: "a1_t0", type: "tool", tool: "read",
                                    state: ToolState(status: "completed", title: "read file",
                                                     output: String(repeating: "x", count: 64)))
        messages[1].info = MessageInfo(
            id: "a1", role: "assistant", modelID: "m", providerID: "p", cost: 0.25,
            tokens: MessageTokens(total: 100, input: 10, output: 20, reasoning: 0, cache: nil),
            time: MessageTime(created: 1_700_000_000_000, completed: 1_700_000_001_000)
        )

        let rows = cache.rows(for: messages, revision: 1)
        XCTAssertEqual(rows[1].message.info.cost, 0.25)
        XCTAssertEqual(rows[1].message.parts[0].state?.output?.count, 64)
        XCTAssertEqual(rows[1].message.info.tokens?.output, 20)
        assertEquivalentCache(cache, messages, revision: 2)
    }

    /// Switching sessions replaces the whole transcript; when the new session
    /// happens to have the same message count, only the revision tells the
    /// cache that nothing about the old rows applies.
    func testSessionSwitchWithSameCountRederives() {
        let cache = TranscriptRowCache()
        let first = [
            user("u1", "first"),
            assistant("a1", reasoning: ["old thought"]),
            user("u2", "again"),
            assistant("a2", text: "old answer"),
        ]
        _ = cache.rows(for: first, revision: 10)

        let second = [
            user("u9", "other"),
            assistant("a9", reasoning: ["new thought"]),
            user("u8", "other again"),
            assistant("a8", text: "new answer"),
        ]
        let rows = cache.rows(for: second, revision: 11)
        XCTAssertEqual(rows.map(\.message.id), ["u9", "a9", "u8", "a8"])
        XCTAssertEqual(rows[1].thinking?.text, "new thought")
        assertEquivalentCache(cache, second, revision: 12)
    }

    /// `body` runs for unrelated `@Published` churn (`isSending`, drafts) that
    /// leaves the transcript alone; the same revision must return the same
    /// rows without folding again.
    func testUnchangedRevisionReturnsMemoizedRows() {
        let cache = TranscriptRowCache()
        let messages = [
            user("u1", "go"),
            assistant("a1", reasoning: ["thought"], text: "answer"),
        ]
        let first = cache.rows(for: messages, revision: 7)
        let second = cache.rows(for: messages, revision: 7)
        XCTAssertEqual(first.map(\.message.id), second.map(\.message.id))
        XCTAssertEqual(first[1].thinking?.text, "thought")
    }

    func testSearchModeOmitsDecorations() {
        let cache = TranscriptRowCache()
        let messages = [
            assistant("a1", reasoning: ["thought"], text: "模型已从 A 更改为 B。"),
        ]
        let rows = cache.rows(for: messages, revision: 0, decorations: false)
        XCTAssertNil(rows.first?.thinking)
        XCTAssertNil(rows.first?.tools)
        XCTAssertNil(rows.first?.modelChangeNotice)
    }

    private func assertEquivalentCache(
        _ cache: TranscriptRowCache,
        _ messages: [MessageRecord],
        revision: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = cache.rows(for: messages, revision: revision)
        let expected = referenceRows(messages)
        XCTAssertEqual(actual.map(\.message.id), expected.map(\.message.id), file: file, line: line)
        for (lhs, rhs) in zip(actual, expected) {
            XCTAssertEqual(lhs.thinking?.text, rhs.thinking?.text, file: file, line: line)
            XCTAssertEqual(lhs.tools?.parts.map(\.id), rhs.tools?.parts.map(\.id), file: file, line: line)
            XCTAssertEqual(lhs.isDateDivider, rhs.isDateDivider, file: file, line: line)
        }
    }
}
