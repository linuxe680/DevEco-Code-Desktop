import SwiftUI
import AppKit

struct MessageBubble: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var providers: ProviderStore
    let message: MessageRecord
    /// 由父视图显式传入：仅正在流式输出的最后一条为 true。
    /// 避免每个气泡都读 store.isSending/messages.last 导致全量重算。
    var isStreaming: Bool = false
    var searchQuery: String = ""
    var aggregatedThinking: String? = nil
    var suppressInlineReasoning: Bool = false
    var groupedTools: [Part]? = nil
    var suppressInlineTools: Bool = false
    var isLastMessage: Bool = false

    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0

    @State private var hovered = false
    @State private var actionBarHovered = false
    @State private var actionsVisible = false
    @State private var hideActionsWorkItem: DispatchWorkItem?
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    private var isStreamingThis: Bool { isStreaming }

    /// Shared effort label mapping used by the composer and message metadata.
    static func effortLabelShared(_ variant: String) -> String {
        switch variant.lowercased() {
        case "none": return NSLocalizedString("None", comment: "effort level")
        case "low": return NSLocalizedString("Low", comment: "effort level")
        case "medium": return NSLocalizedString("Medium", comment: "effort level")
        case "high": return NSLocalizedString("High", comment: "effort level")
        case "xhigh": return NSLocalizedString("Extra high", comment: "effort level")
        case "max": return NSLocalizedString("Max", comment: "effort level")
        case "default": return "default"
        default: return variant.prefix(1).uppercased() + variant.dropFirst()
        }
    }

    /// Plain text content of the message, for copy / export actions.
    private var messageText: String {
        message.parts
            .filter { $0.type == "text" }
            .compactMap { $0.text }
            .joined(separator: "\n\n")
    }

    private var isUser: Bool { message.info.role == "user" }

    private var hasVisibleText: Bool {
        message.parts.contains { part in
            guard part.type == "text" else { return false }
            return !visiblePartText(part.text ?? "", useMarkdown: true).isEmpty
        }
    }

    private var hasAnyVisibleContent: Bool {
        hasVisibleText
            || aggregatedThinking?.isEmpty == false
            || groupedTools?.isEmpty == false
            || message.parts.contains { $0.type == "file" }
    }

    private var usageCapsuleLabel: String? {
        guard let tokens = message.info.tokens else { return nil }
        let total = (tokens.input ?? 0) + (tokens.cache?.read ?? 0)
            + (tokens.output ?? 0) + (tokens.reasoning ?? 0)
        guard total > 0 else { return nil }
        return compactTokenCount(total)
    }

    private var microSize: CGFloat {
        ChatTypography.micro(chatFontSize)
    }

    /// Persistent tail metadata. Token counts must not depend on hover (or on
    /// the server reporting a model id), otherwise a finished reply can look
    /// like it produced no usage at all.
    private var assistantFooterMetadata: String? {
        let info = message.info
        var pieces: [String] = []

        if let modelID = info.modelID {
            let identifier = [info.providerID, info.modelID].compactMap { $0 }.joined(separator: "/")
            let modelName = providers.modelDisplayName(for: identifier, fuzzyModel: modelID)
                .map(prettyModelName)
                ?? modelID
            pieces.append(modelName)
        }

        if let tokens = info.tokens {
            // Harness semantics: input = uncached input of this request,
            // cache.read = context served from cache, output/reasoning =
            // tokens generated for this reply.
            let generated = (tokens.output ?? 0) + (tokens.reasoning ?? 0)
            if generated > 0 {
                pieces.append(String(format: NSLocalizedString("Output %@", comment: "per-message tokens"), compactTokenCount(generated)))
            }
            if let input = tokens.input, input > 0 {
                pieces.append(String(format: NSLocalizedString("Input %@", comment: "per-message uncached tokens"), compactTokenCount(input)))
            }
            if let cached = tokens.cache?.read, cached > 0 {
                pieces.append(String(format: NSLocalizedString("Cached %@", comment: "per-message cache hits"), compactTokenCount(cached)))
            }
        }

        if let variant = info.variant {
            let label = Self.effortLabelShared(variant)
            if label != "default" {
                pieces.append(String(format: NSLocalizedString("Effort: %@", comment: ""), label))
            }
        }
        if let cost = info.cost, cost > 0 {
            pieces.append("$\(String(format: cost < 0.01 ? "%.4f" : "%.2f", cost))")
        }

        guard !pieces.isEmpty else { return nil }
        return pieces.joined(separator: " · ")
    }

    var body: some View {
        Group {
            if isUser {
                userMessage
            } else {
                assistantMessage
            }
        }
        .contextMenu {
            if isUser {
                Button(NSLocalizedString("Edit & resend…", comment: "")) {
                    Task { await store.editMessage(message) }
                }
                Button(NSLocalizedString("Revert to here…", comment: "")) {
                    Task { await store.revert(to: message) }
                }
                .disabled(isStreamingThis)
            } else {
                if isLastMessage {
                    Button(NSLocalizedString("Regenerate", comment: "")) {
                        Task { await store.regenerateLastResponse() }
                    }
                    .disabled(isStreamingThis)
                }
                Button(NSLocalizedString("Revert to here…", comment: "")) {
                    Task { await store.revert(to: message) }
                }
                .disabled(isStreamingThis)
            }
        }
        .onChange(of: isStreamingThis) { streaming in
            if streaming {
                hideActionsImmediately()
            } else {
                updateActionVisibility()
            }
        }
        .onDisappear {
            hideActionsWorkItem?.cancel()
            copyResetTask?.cancel()
            copyResetTask = nil
        }
    }

    private var userMessage: some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 2) {
                userBubble
                if let time = message.info.createdDate {
                    Text(messageTimeLabel(time))
                        .font(.system(size: microSize))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .padding(.trailing, 4)
                }
                hoverActionRow
            }
                .contentShape(Rectangle())
                .onHover { inside in
                    hovered = inside
                    updateActionVisibility()
                }
        }
    }

    private var userBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(message.parts) { part in
                PartView(
                    part: part,
                    useMarkdown: false,
                    isStreaming: isStreamingThis,
                    searchQuery: searchQuery
                )
            }
        }
        .font(.system(size: ChatTypography.body(chatFontSize)))
        .lineSpacing(ChatTypography.lineSpacing(chatFontSize))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 8) {
                if let aggregatedThinking, !aggregatedThinking.isEmpty {
                    ThinkingPanel(text: aggregatedThinking)
                }
                if let groupedTools, !groupedTools.isEmpty {
                    ToolRunPanel(parts: groupedTools)
                }
                ForEach(message.parts.filter {
                    !(suppressInlineReasoning && $0.type == "reasoning")
                        && !(suppressInlineTools && $0.type == "tool")
                }) { part in
                    PartView(
                        part: part,
                        useMarkdown: true,
                        isStreaming: isStreamingThis,
                        searchQuery: searchQuery
                    )
                }

                if hasAnyVisibleContent {
                    HStack(spacing: 6) {
                        if let time = message.info.createdDate {
                            Text(messageTimeLabel(time))
                                .font(.system(size: microSize))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                        if let elapsed = message.info.elapsedDuration {
                            Text(elapsed)
                                .font(.system(size: microSize))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                        if let metadata = assistantFooterMetadata {
                            Text(usageCapsuleLabel ?? NSLocalizedString("Usage", comment: "usage capsule"))
                                .font(.system(size: microSize, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.chipFill, in: Capsule())
                                .help(metadata)
                        }
                    }
                }
            }
            .font(.system(size: ChatTypography.body(chatFontSize)))
            .lineSpacing(ChatTypography.lineSpacing(chatFontSize))
            .padding(.vertical, 3)

            if isUser || hasAnyVisibleContent {
                hoverActionRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { inside in
            hovered = inside
            updateActionVisibility()
        }
    }

    /// The strip keeps a fixed-height slot in the message row. It used to be
    /// an overlay hanging below the bubble: the pointer had to cross an
    /// untracked gap to reach it, so the strip appeared/disappeared and the
    /// scroll view repainted on every crossing (the reported flicker).
    /// Reserving the slot means hover never changes layout and the strip's
    /// hit area is continuous with the bubble. No material and no animation:
    /// both forced a translucent backdrop re-render while scrolling.
    private var hoverActionRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            hoverActionBar
                .opacity(actionsVisible ? 1 : 0)
                .allowsHitTesting(actionsVisible)
                .accessibilityHidden(!actionsVisible)
        }
            // 24pt + the 2pt inner gap + the 8pt stack gap keeps the
            // inter-message rhythm at the previous 34pt.
            .frame(height: 24)
            .onHover { inside in
                actionBarHovered = inside
                updateActionVisibility()
            }
    }

    private func updateActionVisibility() {
        guard !isStreamingThis else {
            hideActionsImmediately()
            return
        }
        if hovered || actionBarHovered {
            hideActionsWorkItem?.cancel()
            hideActionsWorkItem = nil
            actionsVisible = true
        } else {
            scheduleActionHide()
        }
    }

    /// A short grace period covers the gap between the bubble and the strip,
    /// and the hand-off between their two hover tracking areas.
    private func scheduleActionHide() {
        hideActionsWorkItem?.cancel()
        let item = DispatchWorkItem {
            guard !hovered, !actionBarHovered, !isStreamingThis else { return }
            hideActionsWorkItem = nil
            actionsVisible = false
        }
        hideActionsWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    private func hideActionsImmediately() {
        hideActionsWorkItem?.cancel()
        hideActionsWorkItem = nil
        actionBarHovered = false
        actionsVisible = false
    }

    /// Hover action strip: copy, edit & resend (user messages), revert.
    private var hoverActionBar: some View {
        HStack(spacing: 2) {
            if isUser {
                actionButton(
                    copied ? "checkmark" : "doc.on.doc",
                    help: NSLocalizedString("Copy message", comment: ""),
                    tint: copied ? Color.green : Color.secondary
                ) {
                    copyMessage()
                }
            } else {
                if copied {
                    Label(NSLocalizedString("Copied", comment: ""), systemImage: "checkmark.circle.fill")
                        .font(.system(size: ChatTypography.micro(chatFontSize), weight: .medium))
                        .foregroundStyle(.green)
                } else {
                    Menu {
                        Button(NSLocalizedString("Copy answer", comment: "")) { copyMessage() }
                        Button(NSLocalizedString("Copy Markdown", comment: "")) { copyMessage(asMarkdown: true) }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Color.secondary)
                        }
                        .padding(4)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(NSLocalizedString("Copy answer", comment: ""))
                }
            }
            if message.info.role == "user" {
                actionButton("pencil", help: NSLocalizedString("Edit & resend…", comment: "")) {
                    Task { await store.editMessage(message) }
                }
            } else if isLastMessage {
                actionButton("arrow.clockwise", help: NSLocalizedString("Regenerate", comment: "")) {
                    Task { await store.regenerateLastResponse() }
                }
            }
            actionButton("clock.arrow.circlepath", help: NSLocalizedString("Revert to here…", comment: "")) {
                Task { await store.revert(to: message) }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Theme.chromeFill, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.softStroke))
        .padding(.horizontal, 6)
    }

    private func actionButton(_ systemImage: String, help: String, tint: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(tint)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func copyMessage() {
        copyMessage(asMarkdown: false)
    }

    private func copyMessage(asMarkdown: Bool) {
        guard !messageText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        if asMarkdown {
            let markdown = message.parts
                .filter { $0.type == "text" }
                .compactMap { $0.text }
                .joined(separator: "\n\n")
            NSPasteboard.general.setString(markdown, forType: .string)
        } else {
            NSPasteboard.general.setString(messageText, forType: .string)
        }
        copied = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }

}

struct TodoPanel: View {
    let todos: [TodoItem]
    @State private var expanded = true

    private var doneCount: Int { todos.filter(\.isDone).count }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(todos) { todo in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        statusIcon(todo)
                            .font(.system(size: 13))
                        Text(todo.content)
                            .font(.system(size: 14))
                            .strikethrough(todo.isDone || todo.isCancelled)
                            .foregroundStyle(todo.isDone || todo.isCancelled ? .secondary : .primary)
                    }
                }
            }
            .padding(.leading, 8)
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                Text(NSLocalizedString("Todos", comment: ""))
                    .font(.system(size: 14, weight: .semibold))
                Text("\(doneCount)/\(todos.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.chromeFill)
    }

    @ViewBuilder
    private func statusIcon(_ todo: TodoItem) -> some View {
        if todo.isDone {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if todo.isCancelled {
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        } else if todo.isInProgress {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
        } else {
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}

/// Reveals assistant text at a comfortable reading speed even when the
/// server delivers the whole reply in one burst. Follows live deltas closely
/// when they arrive gradually; when `isStreaming` flips false after a burst,
/// it keeps draining the remaining backlog instead of snapping to the end.
private struct StreamingTextView: View {
    let target: String
    let useMarkdown: Bool
    var isStreaming: Bool = false
    let searchQuery: String

    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0
    @StateObject private var reveal = StreamingReveal()

    /// True while the server is actually appending to the transcript. The
    /// `isStreaming` flag alone flips false the moment the network run ends,
    /// which made cached large replies snap to their final glyph instead of
    /// finishing the typewriter pass.
    private var revealIsStreaming: Bool {
        isStreaming || (reveal.activated && !reveal.finished)
    }

    /// Historical messages (never streaming) render the full text instantly.
    /// Only bubbles that actually went through a live run use the typewriter.
    private var isTypewriterActive: Bool {
        reveal.activated && !reveal.finished
    }

    private var shown: String {
        if !reveal.activated {
            return target
        }
        return reveal.text
    }

    /// A bubble is live only while the server is appending or the typewriter
    /// is still catching up. A live reply renders as one plain-text block so
    /// it never appears twice or changes block spacing mid-stream; the full
    /// Markdown renderer takes over once the run ends.
    private var isLive: Bool {
        isStreaming || isTypewriterActive
    }

    private var plainContent: String {
        guard isLive, !shown.isEmpty, !shown.hasSuffix("\n") else { return shown }
        return shown + "▍"
    }

    var body: some View {
        Group {
            if useMarkdown {
                // A live reply is one plain-text block. Rendering a Markdown
                // prefix beside a plain tail made the same answer appear in
                // two places and changed block spacing whenever the boundary
                // crossed a newline (the "text jumps" the user reported).
                // The full Markdown renderer takes over once the run ends.
                if isLive {
                    linkText(plainContent, searchQuery: searchQuery)
                } else {
                    MarkdownContentView(content: shown, searchQuery: searchQuery)
                }
            } else if !searchQuery.isEmpty,
                      let attributed = highlightedAttributedString(plainContent, query: searchQuery) {
                Text(attributed)
                    .font(.system(size: ChatTypography.body(chatFontSize)))
                    .lineSpacing(ChatTypography.lineSpacing(chatFontSize))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44, alignment: .topLeading)
            } else {
                linkText(plainContent, searchQuery: searchQuery)
            }
        }
        .onAppear { reveal.update(target: target, isStreaming: revealIsStreaming) }
        .onChange(of: target) { newTarget in reveal.update(target: newTarget, isStreaming: revealIsStreaming) }
        .onChange(of: revealIsStreaming) { newValue in reveal.update(target: target, isStreaming: newValue) }
    }
}

/// One timer per streaming bubble, on the main run loop, publishing at most
/// every 24ms. Grapheme clusters are honored so Chinese and emoji are never
/// cut in half.
@MainActor
final class StreamingReveal: ObservableObject {
    @Published private(set) var text = ""

    /// Grapheme cluster buffer for the current target. A stream normally
    /// appends, so this grows incrementally instead of rebuilding a prefix
    /// string on every 24ms tick.
    private var characters: [Character] = []
    private var displayedCount = 0
    private var lastTick = Date.distantPast
    /// At most one queued tick. Without this, a burst of `update` calls could
    /// start several independent asyncAfter chains that all mutate `text`.
    private var tickScheduled = false
    /// Set only when the bubble has actually been in a live streaming state.
    private(set) var activated = false
    var finished: Bool { displayedCount >= characters.count }

    /// ~62 glyphs/second: fast enough for short answers, slow enough that a
    /// one-shot 300-glyph burst visibly types over a few seconds.
    private static let glyphsPerSecond = 62.0
    private static let minInterval = 0.024

    func update(target newTarget: String, isStreaming newStreaming: Bool) {
        if newStreaming {
            if !activated {
                activated = true
                lastTick = Date()
            }
        }
        let oldCount = characters.count
        if newTarget.count > oldCount,
           oldCount > 0,
           newTarget.prefix(oldCount).elementsEqual(characters) {
            characters.append(contentsOf: newTarget.dropFirst(oldCount))
        } else if newTarget.count < oldCount {
            // A reverted tail clamps in place. Rebuilding on a shrink is rare;
            // it must not replay the whole answer from the seed glyphs.
            characters = Array(newTarget)
            displayedCount = characters.count
            text = newTarget
        } else if !newTarget.elementsEqual(characters) {
            let common = zip(text, newTarget).prefix { $0 == $1 }.count
            characters = Array(newTarget)
            displayedCount = min(common, characters.count)
            text = String(characters.prefix(displayedCount))
        }
        guard activated else { return }
        if newStreaming && displayedCount == 0 && !characters.isEmpty {
            advance(min(6, characters.count))
        }
        if !newStreaming && displayedCount == 0 {
            displayedCount = characters.count
            text = newTarget
            return
        }
        ensureTicking()
    }

    private func ensureTicking() {
        guard displayedCount < characters.count else {
            // Caught up with the transcript. Never rewind: a partial reveal
            // that shrinks while the server is still appending makes the tail
            // flicker (and can strand a lone caret glyph on its own line).
            text = String(characters)
            return
        }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTick)
        guard elapsed >= Self.minInterval else {
            // Arriving early (e.g. right after activation) must still leave a
            // timer behind; otherwise a short reply freezes mid-sentence when
            // the stream ends before the next update arrives.
            scheduleTick(after: Self.minInterval - elapsed)
            return
        }
        let step = max(1, min(3, Int(Self.glyphsPerSecond * elapsed)))
        lastTick = now
        advance(step)
        if displayedCount < characters.count {
            scheduleTick(after: Self.minInterval)
        }
    }

    private func advance(_ step: Int) {
        let next = min(step, characters.count - displayedCount)
        guard next > 0 else { return }
        let end = displayedCount + next
        text.append(contentsOf: characters[displayedCount..<end])
        displayedCount = end
    }

    private func scheduleTick(after delay: TimeInterval) {
        guard !tickScheduled else { return }
        tickScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            guard let self else { return }
            self.tickScheduled = false
            self.ensureTicking()
        }
    }
}

private struct PartView: View {
    let part: Part
    let useMarkdown: Bool
    var isStreaming: Bool = false
    /// When set (⌘F search active), plain-text parts highlight the matches.
    var searchQuery: String = ""

    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0

    var body: some View {
        switch part.type {
        case "text":
            let text = part.text ?? ""
            let visibleText = visiblePartText(text, useMarkdown: useMarkdown)
            if visibleText.isEmpty {
                EmptyView()
            } else {
                StreamingTextView(
                    target: visibleText,
                    useMarkdown: useMarkdown,
                    isStreaming: isStreaming,
                    searchQuery: searchQuery
                )
            }
        case "reasoning":
            ThinkingPanel(text: part.text ?? "")
        case "tool":
            ToolCardView(part: part)
        case "step", "subtask", "task":
            TaskTraceCard(part: part)
        case "file":
            if let filename = part.filename {
                AttachmentChip(filename: filename, mime: part.mime, urlString: part.url)
            }
        case "step-start", "step-finish", "snapshot", "patch":
            EmptyView()
        default:
            Text(part.text ?? part.type)
                .font(.system(size: ChatTypography.meta(chatFontSize)))
                .foregroundStyle(.secondary)
        }
    }
}

private struct ThinkingPanel: View {
    let text: String

    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0
    @State private var expanded: Bool

    init(text: String) {
        self.text = text
        _expanded = State(initialValue: AppSettings.expandThinking)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.system(size: ChatTypography.meta(chatFontSize)))
                .lineSpacing(ChatTypography.lineSpacing(chatFontSize))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)
        } label: {
            // DisclosureGroup draws its own chevron; adding one here
            // rendered a doubled arrow.
            Text(NSLocalizedString("Thinking", comment: ""))
                .font(.system(size: ChatTypography.micro(chatFontSize), weight: .medium))
                .foregroundStyle(.quaternary)
        }
    }
}

private struct ToolRunPanel: View {
    let parts: [Part]

    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0
    @State private var expanded = false

    private var isRunning: Bool {
        parts.contains { $0.state?.status == "running" }
    }

    private var summary: String {
        String(
            format: NSLocalizedString("Execution · %d steps", comment: ""),
            parts.count
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 6 : 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isRunning ? "gearshape.2" : "list.bullet.rectangle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(summary)
                        .font(.system(size: ChatTypography.micro(chatFontSize), weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(parts) { part in
                        ToolCardView(part: part)
                    }
                }
            }
        }
    }
}
