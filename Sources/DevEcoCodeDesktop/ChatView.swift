import SwiftUI
import AppKit

struct ChatView: View {
    @Binding var showSearch: Bool
    @Binding var section: AppSection
    let openWorkPanelTab: (WorkPanelTab) -> Void

    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var providers: ProviderStore
    @EnvironmentObject var server: ServerManager

    /// Keep the conversation readable on wide displays; Codex-style centered column.
    private let contentMaxWidth: CGFloat = 740
    /// Stable scroll target for the inline failure card at the transcript tail.
    private static let inlineErrorAnchor = "inline-error-anchor"

    @AppStorage(AppSettings.Keys.autoScroll)
    private var autoScroll = true
    @AppStorage(AppSettings.Keys.sendOnEnter)
    private var sendOnEnter = true
    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0

    /// False once the user scrolls away from the tail; pauses stream follow
    /// and reveals the "Back to latest" pill.
    @State private var isNearBottom = true
    /// Incremental transcript-row derivation, so a streaming delta does not
    /// re-fold the whole conversation on every body evaluation.
    @State private var transcriptRows = TranscriptRowCache()
    /// True when the transcript is shorter than the viewport. Auto-scroll is
    /// pointless then, and `scrollTo(anchor: .bottom)` overscrolls such short
    /// transcripts so the first message gets clipped under the top row.
    @State private var transcriptFitsViewport = false
    /// Scroll position as a fraction of the scrollable content height.
    @State private var transcriptScrollProgress: CGFloat = 0

    /// The most recent tool part still running, for the sticky activity bar.
    private var runningTool: Part? {
        for message in store.messages.reversed() {
            if let part = message.parts.last(where: { $0.type == "tool" && $0.state?.status == "running" }) {
                return part
            }
        }
        return nil
    }

    private var canSend: Bool {
        !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && store.selectedSessionID != nil
    }

    @State private var historyIndex: Int?
    @State private var draftBeforeHistory = ""
    @State private var inputHeight: CGFloat = 52
    @State private var paletteIndex = 0
    @State private var focusTrigger = 0
    @State private var mentionResults: [FsEntry] = []
    @State private var mentionIndex = 0
    @State private var mentionDebounce: Task<Void, Never>?
    @State private var searchQuery = ""
    @State private var searchMatchIndex = 0
    @State private var searchJumpTick = 0
    /// Measured height of the queued-prompt strip (0 when it is hidden).
    @State private var queuedStripHeight: CGFloat = 0
    @FocusState private var searchFocused: Bool
    @State private var dragHover = false
    @State private var showModelPicker = false
    @State private var modelQuery = ""
    @State private var modelSection = "all"
    @FocusState private var modelSearchFocused: Bool
    /// Set on send so the next clear-draft render cannot refocus the input
    /// and steal focus from the transcript while the agent starts working.
    @State private var suppressFocusOnce = false

    private func applyCompletion(_ command: DevCommand) {
        let oldDraft = store.draft
        store.draft = "/" + command.name + " "
        if store.draft != oldDraft { store.bumpDraftToken() }
        focusTrigger += 1
    }

    /// The trailing "@query" token of the draft, if any — drives the file
    /// mention popup.
    private var mentionToken: String? {
        Self.mentionToken(in: store.draft)
    }

    /// Splits on whitespace AND newlines so @-mentions work after
    /// Shift+Enter line breaks too.
    static func mentionToken(in draft: String) -> String? {
        let last = draft
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .last.map(String.init) ?? ""
        guard last.hasPrefix("@"), last.count >= 1 else { return nil }
        return String(last.dropFirst())
    }

    private var mentionMatches: [FsEntry] {
        mentionToken == nil ? [] : mentionResults
    }

    private func updateMentionResults() {
        mentionDebounce?.cancel()
        guard let query = mentionToken else {
            mentionResults = []
            return
        }
        // Debounced: one fs/find per 180ms pause instead of per keystroke.
        // Empty query ("@" alone) also fetches, so the picker appears at once.
        mentionDebounce = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let results = await store.findFiles(query: query)
            guard (mentionToken ?? "") == query, !Task.isCancelled else { return }
            mentionResults = Array(results.prefix(8))
        }
    }

    private func attachMention(_ entry: FsEntry) {
        if let token = mentionToken, let range = store.draft.range(of: "@" + token, options: .backwards) {
            store.draft.removeSubrange(range)
            store.bumpDraftToken()
        }
        mentionResults = []
        let fileURL = server.projectDirectory.appendingPathComponent(entry.path)
        store.addFileAttachment(url: fileURL)
        focusTrigger += 1
    }

    private func handlePaletteUp() -> Bool {
        if !mentionMatches.isEmpty {
            mentionIndex = (mentionIndex - 1 + mentionMatches.count) % mentionMatches.count
            return true
        }
        guard !commandMatches.isEmpty else { return false }
        paletteIndex = (paletteIndex - 1 + commandMatches.count) % commandMatches.count
        return true
    }

    private func handlePaletteDown() -> Bool {
        if !mentionMatches.isEmpty {
            mentionIndex = (mentionIndex + 1) % mentionMatches.count
            return true
        }
        guard !commandMatches.isEmpty else { return false }
        paletteIndex = (paletteIndex + 1) % commandMatches.count
        return true
    }

    private func handlePaletteTab() -> Bool {
        if !mentionMatches.isEmpty {
            let index = min(mentionIndex, mentionMatches.count - 1)
            attachMention(mentionMatches[index])
            return true
        }
        guard !commandMatches.isEmpty else { return false }
        let index = min(paletteIndex, commandMatches.count - 1)
        applyCompletion(commandMatches[index])
        return true
    }

    /// Enter with a palette visible completes the highlighted candidate
    /// instead of sending. "@" always completes; "/" only completes while no
    /// arguments are typed yet, so "/cmd args" still sends normally.
    private func handlePaletteReturn() -> Bool {
        if !mentionMatches.isEmpty {
            let index = min(mentionIndex, mentionMatches.count - 1)
            attachMention(mentionMatches[index])
            return true
        }
        if store.draft.hasPrefix("/"), !store.draft.contains(" "), !commandMatches.isEmpty {
            let index = min(paletteIndex, commandMatches.count - 1)
            applyCompletion(commandMatches[index])
            return true
        }
        return false
    }

    /// Escape unwinds overlays first (candidate popup), then aborts a run.
    private func handleEscape() {
        if showSearch {
            closeSearch()
            return
        }
        if showModelPicker {
            showModelPicker = false
            return
        }
        if !mentionMatches.isEmpty {
            // Drop the trailing "@query" token so the popup stays closed.
            if let token = mentionToken,
               let range = store.draft.range(of: "@" + token, options: .backwards) {
                store.draft.removeSubrange(range)
                store.bumpDraftToken()
            }
            mentionResults = []
            return
        }
        if store.isSending {
            store.abort()
        }
    }

    private func addPastedFiles(_ urls: [URL]) {
        for url in urls {
            if url.path.hasPrefix(server.projectDirectory.path) {
                store.addFileAttachment(url: url)
            } else {
                store.errorMessage = String(
                    format: NSLocalizedString("Attachment must be inside the project directory: %@", comment: ""),
                    server.projectDirectory.path
                )
                return
            }
        }
    }

    /// Composer "+" menu, mirroring Codex's attachment entry point. Files are
    /// limited to the project directory because the server can only read paths
    /// inside the workspace it was started for.
    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = server.projectDirectory
        panel.prompt = NSLocalizedString("Attach", comment: "composer attach button")
        guard panel.runModal() == .OK else { return }
        addPastedFiles(panel.urls)
        focusTrigger += 1
    }

    private func historyUp() {
        let history = AppSettings.promptHistory
        guard !history.isEmpty else { return }
        let oldDraft = store.draft
        if historyIndex == nil {
            draftBeforeHistory = store.draft
            historyIndex = 0
        } else if let current = historyIndex, current + 1 < history.count {
            historyIndex = current + 1
        }
        let index = historyIndex ?? 0
        store.draft = history[history.count - 1 - index]
        if store.draft != oldDraft { store.bumpDraftToken() }
    }

    /// Pure index math for Option+↓ recall. `nil` means "return to the saved
    /// draft" (no history, or stepped back past the newest entry). Clamping
    /// keeps a stale `current` safe if history was cleared/truncated in
    /// another window while this composer was mid-recall.
    nonisolated static func historyDownIndex(current: Int, historyCount: Int) -> Int? {
        guard historyCount > 0, current > 0 else { return nil }
        let steps = min(current - 1, historyCount - 1)
        return historyCount - 1 - steps
    }

    private func historyDown() {
        let history = AppSettings.promptHistory
        guard let current = historyIndex else { return }
        let oldDraft = store.draft
        guard let index = Self.historyDownIndex(current: current, historyCount: history.count) else {
            historyIndex = nil
            store.draft = draftBeforeHistory
            if store.draft != oldDraft { store.bumpDraftToken() }
            return
        }
        historyIndex = current - 1
        store.draft = history[index]
        if store.draft != oldDraft { store.bumpDraftToken() }
    }
    private var commandMatches: [DevCommand] {
        guard store.draft.hasPrefix("/"), !store.commands.isEmpty else { return [] }
        let typed = store.draft.dropFirst().split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        if typed.isEmpty {
            return Array(store.commands.prefix(8))
        }
        return Array(store.commands.filter { $0.name.contains(typed.lowercased()) }.prefix(8))
    }

    var body: some View {
        VStack(spacing: 0) {
            chatTopBar
            if store.selectedSessionID == nil {
                emptyState
            } else {
                sessionArea
            }
        }
        .background(Theme.canvas)
        // The split view re-applies the window's top inset per pane; opt out
        // so this row shares the titlebar row instead of sitting 28pt lower.
        .ignoresSafeArea(.container, edges: .top)
        // Codex floats a compact find field over the transcript's top-right
        // corner instead of inserting a full-width strip that squeezes it.
        .overlay(alignment: .topTrailing) {
            if showSearch, store.selectedSessionID != nil {
                searchOverlay
                    .padding(.top, 12)
                    .padding(.trailing, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.14), value: showSearch)
        .onAppear {
            MarkdownCache.configure()
            ImageCache.configure()
        }
    }

    /// The transcript's own top row. Codex keeps this seamless with the
    /// canvas: the project path on the left, transcript actions on the right.
    private var chatTopBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(server.projectDirectory.path)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let branch = store.vcsBranch, !branch.isEmpty {
                Text(branch)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.chipFill)
                    .clipShape(Capsule())
            }
            Spacer(minLength: 8)
            if store.selectedSessionID != nil {
                TranscriptToolbarActions(openWorkPanelTab: openWorkPanelTab)
            }
            AppChromeControls()
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    /// Full-area empty state: opaque so the input underneath is clearly not
    /// interactive, with an explicit call to action.
    private var emptyState: some View {
        VStack(spacing: 14) {
            if store.needsConsent {
                ConsentCard(
                    agreement: store.productAgreement,
                    isAccepting: store.isAcceptingConsent,
                    onAccept: {
                        Task { await store.acceptConsent() }
                    }
                )
                .padding(.horizontal, 24)
            } else {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(NSLocalizedString("Select a session or create a new one", comment: ""))
                    .foregroundStyle(.secondary)
                if server.state == .running {
                    Button {
                        store.createSession()
                    } label: {
                        Label(NSLocalizedString("New Session", comment: ""), systemImage: "plus.circle.fill")
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    HStack(spacing: 6) {
                        if server.state == .starting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(serverStatusLabel)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if server.state == .stopped || server.state == .failed {
                        Button(NSLocalizedString("Start Server", comment: "")) { server.start() }
                            .controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }

    private var serverStatusLabel: String {
        switch server.state {
        case .running: return NSLocalizedString("Connected", comment: "")
        case .starting: return NSLocalizedString("Starting…", comment: "")
        case .failed: return NSLocalizedString("Failed", comment: "")
        case .stopped: return NSLocalizedString("Stopped", comment: "")
        }
    }

    private var projectName: String {
        let name = server.projectDirectory.lastPathComponent
        return name.isEmpty ? server.projectDirectory.path : name
    }

    /// Compact floating find field, anchored to the transcript's top-right.
    private var searchOverlay: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(NSLocalizedString("Search in conversation", comment: ""), text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit {
                    // Enter = next match, Shift+Enter = previous.
                    let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                    jumpSearch(backwards ? -1 : 1)
                }

            if !searchQuery.isEmpty {
                Text(searchMatchIndex < visibleMessages.count
                     ? "\(searchMatchIndex + 1)/\(visibleMessages.count)"
                     : "0/0")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }

            Button { jumpSearch(-1) } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(visibleMessages.isEmpty)
            .help(NSLocalizedString("Previous match", comment: ""))

            Button { jumpSearch(1) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(visibleMessages.isEmpty)
            .help(NSLocalizedString("Next match", comment: ""))

            Button {
                closeSearch()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Close search", comment: ""))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 336)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Theme.softStroke)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        .onExitCommand { closeSearch() }
        .onAppear {
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private func closeSearch() {
        showSearch = false
        searchQuery = ""
        searchMatchIndex = 0
        searchFocused = false
    }

    private func useStarterPrompt(_ prompt: String) {
        let oldDraft = store.draft
        store.draft = prompt
        if store.draft != oldDraft { store.bumpDraftToken() }
        focusTrigger += 1
    }

    /// A purposeful first-run surface instead of an empty transcript.
    private var newConversationState: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 5) {
                    Text(NSLocalizedString("Start a conversation", comment: ""))
                        .font(.title3.weight(.semibold))
                    Text(String(
                        format: NSLocalizedString("Ask DevEco to explore, change, or test %@.", comment: ""),
                        projectName
                    ))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(NSLocalizedString("Current project", comment: ""))
                    .font(.system(size: 14, weight: .medium))
                Text(server.projectDirectory.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.subtleFill)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(spacing: 8) {
                StarterPromptButton(
                    systemImage: "map",
                    title: NSLocalizedString("Explore this project", comment: ""),
                    detail: NSLocalizedString("Explain the architecture, entry points, and how to run it.", comment: "")
                ) {
                    useStarterPrompt(NSLocalizedString(
                        "Explore this project and explain its architecture, main entry points, and how to run and test it.",
                        comment: ""
                    ))
                }
                StarterPromptButton(
                    systemImage: "ladybug",
                    title: NSLocalizedString("Find and fix a bug", comment: ""),
                    detail: NSLocalizedString("Review the highest-impact issue, fix the root cause, and verify it.", comment: "")
                ) {
                    useStarterPrompt(NSLocalizedString(
                        "Review this project for the highest-impact bug. Explain the root cause, fix it, and run the relevant tests.",
                        comment: ""
                    ))
                }
                StarterPromptButton(
                    systemImage: "checkmark.seal",
                    title: NSLocalizedString("Run and fix tests", comment: ""),
                    detail: NSLocalizedString("Run the test suite, diagnose failures, and fix them.", comment: "")
                ) {
                    useStarterPrompt(NSLocalizedString(
                        "Run this project's test suite, diagnose any failures, fix them, and rerun the tests.",
                        comment: ""
                    ))
                }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 64)
    }

    /// Full request context of the last assistant turn versus the selected
    /// model's limit. The same 20k context appears on every reply in a long
    /// chat, so this drives a warning near the limit instead of a permanent
    /// composer readout. Tapping the composer ring opens the breakdown popover.
    private var contextUsage: (used: Double, limit: Double?, tokens: MessageTokens?)? {
        let effectiveModel = store.selectedModel
            ?? (store.serverDefaultModel.isEmpty ? nil : store.serverDefaultModel)
        let limit = providers.contextLimit(for: effectiveModel)
        let lastAssistant = store.messages.last(where: { $0.info.role == "assistant" })
        let tokens: MessageTokens?
        if let context = lastAssistant?.info.tokens?.contextUsed, context > 0 {
            tokens = lastAssistant?.info.tokens
        } else if let previous = store.messages.reversed().dropFirst(
            lastAssistant == nil ? 0 : 1
        ).first(where: { $0.info.role == "assistant" && ($0.info.tokens?.contextUsed ?? 0) > 0 }) {
            tokens = previous.info.tokens
        } else {
            tokens = lastAssistant?.info.tokens
        }
        let used = tokens?.contextUsed ?? 0
        guard limit != nil || used > 0 else { return nil }
        return (used, limit, tokens)
    }

    private var contextWarning: String? {
        guard let usage = contextUsage,
              let limit = usage.limit, limit > 0 else { return nil }
        let ratio = min(max(usage.used / limit, 0), 1)
        guard ratio >= 0.8 else { return nil }
        return String(
            format: NSLocalizedString("Context is %d%% full — compact the conversation to keep replies reliable.", comment: "context warning above composer"),
            Int((ratio * 100).rounded())
        )
    }

    /// Derived transcript rows (day dividers, merged reasoning, grouped tool
    /// runs, model-change notices), memoized so a streaming delta re-folds
    /// only the tail instead of walking the whole conversation. The cache is
    /// keyed by `store.transcriptRevision`, which bumps on every mutation.
    private var messageRows: [MessageRow] {
        if searchQuery.isEmpty {
            return transcriptRows.rows(for: store.messages, revision: store.transcriptRevision)
        }
        return transcriptRows.rows(
            for: visibleMessages,
            revision: store.transcriptRevision,
            decorations: false
        )
    }

    /// ⌘F match list, memoized per revision/query so every keystroke and every
    /// streamed delta does not rescan the whole transcript.
    private var visibleMessages: [MessageRecord] {
        guard !searchQuery.isEmpty else { return store.messages }
        return transcriptRows.matches(
            in: store.messages,
            query: searchQuery,
            revision: store.transcriptRevision
        )
    }


    @ViewBuilder
    private func messageRowView(_ row: MessageRow) -> some View {
        if let date = row.message.info.createdDate, row.isDateDivider {
            TimelineDivider(text: conversationDateLabel(date))
        }
        if let notice = row.modelChangeNotice {
            TimelineDivider(text: notice, symbol: "cube")
        }
        MessageBubble(
            message: row.message,
            isStreaming: StreamRenderText.shouldTypewrite(
                row.message,
                isSending: store.isSending,
                isLast: row.message.id == store.messages.last?.id
            ),
            searchQuery: searchQuery,
            aggregatedThinking: row.thinking?.anchorID == row.message.id ? row.thinking?.text : nil,
            suppressInlineReasoning: row.thinking != nil,
            groupedTools: row.tools?.anchorID == row.message.id ? row.tools?.parts : nil,
            suppressInlineTools: row.tools != nil,
            isLastMessage: row.message.id == store.messages.last?.id
        )
        .id(row.message.id)
    }

    /// Enter (next) / Shift+Enter (previous) cycle through the matches.
    private func jumpSearch(_ direction: Int) {
        let matches = visibleMessages
        guard !matches.isEmpty else { return }
        searchMatchIndex = (searchMatchIndex + direction + matches.count) % matches.count
        searchJumpTick += 1
    }

    /// The model the picker resolves to: the explicit pick, or the server's
    /// configured default while the session follows "Server default".
    private var resolvedModelChoice: ModelChoice? {
        let id = store.selectedModel ?? providers.defaultModel
        guard !id.isEmpty else { return nil }
        return providers.allModelChoices.first { $0.id == id }
    }

    private var serverDefaultMenuLabel: String {
        let base = NSLocalizedString("Server default", comment: "")
        guard let choice = resolvedModelChoice, store.selectedModel == nil else {
            return base
        }
        return "\(base) · \(prettyModelName(choice.name))"
    }

    private var selectedModelLabel: String {
        guard let choice = resolvedModelChoice else {
            return NSLocalizedString("Server default", comment: "")
        }
        return prettyModelName(choice.name)
    }

    private var selectedModelProvider: String? {
        resolvedModelChoice?.provider
    }

    private var selectedEffortLabel: String {
        let value = store.selectedVariant.map(effortLabel) ?? NSLocalizedString("Default", comment: "default level")
        return String(format: NSLocalizedString("Effort: %@", comment: ""), value)
    }

    /// The model whose variants drive the effort picker. When the session is
    /// on "Server default", resolve the configured default model so the
    /// selector does not disappear in brand-new sessions.
    private var effortModelID: String? {
        store.selectedModel ?? (providers.defaultModel.isEmpty ? nil : providers.defaultModel)
    }

    private var effortVariants: [String] {
        providers.variants(for: effortModelID)
    }

    private func effortLabel(_ variant: String) -> String {
        MessageBubble.effortLabelShared(variant)
    }

    private func selectEffort(_ variant: String?) {
        // A variant is only meaningful for a concrete model. Pin the
        // currently-effective model before applying it.
        if store.selectedModel == nil, let resolved = effortModelID {
            store.selectedModel = resolved
        }
        store.selectedVariant = variant
        focusTrigger += 1
    }

    /// Composer model picker: a Codex-style sheet with type-to-filter (64+
    /// models make a nested menu painful) and a "recent" section.
    private var composerModelMenu: some View {
        Button {
            modelQuery = ""
            showModelPicker = true
        } label: {
            HStack(spacing: 4) {
                Text(selectedModelLabel)
                    .lineLimit(1)
                if let provider = selectedModelProvider, !selectedModelLabel.contains("·") {
                    Text(provider)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .font(.system(size: ChatTypography.meta(chatFontSize), weight: .medium))
            .foregroundStyle(.primary)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(-1)
        .help(NSLocalizedString("Choose model for this session", comment: ""))
        .sheet(isPresented: $showModelPicker) {
            modelPickerContent
        }
    }

    private var modelPickerContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                TextField("Search models…", text: $modelQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($modelSearchFocused)
                    .onSubmit { pickFirstModelResult() }
                if !modelQuery.isEmpty {
                    Button { modelQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                Divider()
                    .frame(height: 14)
                Button {
                    showModelPicker = false
                    section = .providers
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("Manage models and providers", comment: ""))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.chromeFill, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 14)
            .padding(.top, 14)
            Divider()

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    if modelQuery.isEmpty, !recentModelChoices.isEmpty {
                        modelSectionButton(
                            id: "recent",
                            title: NSLocalizedString("Recent", comment: "model picker"),
                            count: recentModelChoices.count
                        )
                    }
                    ForEach(filteredModelGroups) { group in
                        modelSectionButton(id: group.provider, title: group.provider, count: group.choices.count)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 148)
                .padding(.vertical, 6)
                .background(Theme.chromeFill)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if modelSection == "all" {
                            modelPickerRow(id: nil, name: serverDefaultMenuLabel, provider: nil) {
                                pickModel(nil)
                            }
                            Divider().padding(.vertical, 4)
                        }
                        if modelSection == "recent" {
                            pickerSectionHeader(NSLocalizedString("Recent", comment: "model picker"))
                            ForEach(recentModelChoices) { choice in
                                modelPickerRow(id: choice.id, name: choice.name, provider: choice.provider) {
                                    pickModel(choice.id)
                                }
                            }
                        } else {
                            ForEach(sectionGroups) { group in
                                if modelSection == "all" {
                                    pickerSectionHeader(group.provider)
                                }
                                ForEach(group.choices) { choice in
                                    modelPickerRow(id: choice.id, name: choice.name, provider: nil) {
                                        pickModel(choice.id)
                                    }
                                }
                            }
                        }
                        if sectionGroups.isEmpty && (modelSection != "recent" || recentModelChoices.isEmpty) {
                            Text(String(format: NSLocalizedString("No models match “%@”", comment: ""), modelQuery))
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .padding(12)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 560)
        .padding(.bottom, 10)
        .onChange(of: modelQuery) { _ in
            if !modelQuery.isEmpty { modelSection = "all" }
        }
        .onAppear {
            DispatchQueue.main.async { modelSearchFocused = true }
        }
        .onExitCommand { showModelPicker = false }
    }

    private var sectionGroups: [ModelGroup] {
        if modelSection == "recent" || modelSection == "all" {
            return filteredModelGroups
        }
        return filteredModelGroups.filter { $0.provider == modelSection }
    }

    private func modelSectionButton(id: String, title: String, count: Int? = nil) -> some View {
        Button {
            modelSection = id
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(modelSection == id ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 5, height: 5)
                Text(title)
                    .font(.system(size: 12, weight: modelSection == id ? .semibold : .regular))
                    .foregroundStyle(modelSection == id ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Enter in the search field picks the first visible row, matching the
    /// command-palette style of the rest of the app.
    private func pickFirstModelResult() {
        if modelSection == "recent", let first = recentModelChoices.first {
            pickModel(first.id)
            return
        }
        if let first = sectionGroups.first?.choices.first {
            pickModel(first.id)
        }
    }

    private var recentModelChoices: [ModelChoice] {
        let choicesById = Dictionary(
            uniqueKeysWithValues: providers.allModelChoices.map { ($0.id, $0) }
        )
        return AppSettings.recentModels.compactMap { choicesById[$0] }
    }

    private var filteredModelGroups: [ModelGroup] {
        let query = modelQuery.trimmingCharacters(in: .whitespaces)
        let choices: [ModelChoice]
        if query.isEmpty {
            choices = providers.allModelChoices
        } else {
            choices = providers.allModelChoices.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.provider.localizedCaseInsensitiveContains(query)
                    || $0.id.localizedCaseInsensitiveContains(query)
            }
        }
        return Dictionary(grouping: choices, by: \.provider)
            .map { ModelGroup(provider: $0.key, choices: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.provider < $1.provider }
    }

    private func pickerSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func modelPickerRow(
        id: String?,
        name: String,
        provider: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let provider, !provider.isEmpty {
                        Text(provider)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if let choice = modelChoice(id) {
                    if choice.contextWindow > 0 {
                        Text(compactTokenCount(Double(choice.contextWindow)))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    if choice.reasoning {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                            .foregroundStyle(.purple)
                            .help(NSLocalizedString("Reasoning model", comment: "model badge"))
                    }
                }
                if id == store.selectedModel {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func modelChoice(_ id: String?) -> ModelChoice? {
        guard let id else { return nil }
        return providers.allModelChoices.first { $0.id == id }
    }

    private func pickModel(_ id: String?) {
        store.selectedModel = id
        if let id {
            AppSettings.rememberRecentModel(id)
        }
        focusTrigger += 1
        showModelPicker = false
    }

    private var composerEffortMenu: some View {
        Menu {
            Button {
                selectEffort(nil)
            } label: {
                if store.selectedVariant == nil {
                    Label(NSLocalizedString("Default", comment: "default level"), systemImage: "checkmark")
                } else {
                    Text(NSLocalizedString("Default", comment: "default level"))
                }
            }
            Divider()
            ForEach(effortVariants, id: \.self) { variant in
                Button {
                    selectEffort(variant)
                } label: {
                    if store.selectedVariant == variant {
                        Label(effortLabel(variant), systemImage: "checkmark")
                    } else {
                        Text(effortLabel(variant))
                    }
                }
            }
        } label: {
            Text(selectedEffortLabel)
                .lineLimit(1)
                .font(.system(size: ChatTypography.meta(chatFontSize), weight: .medium))
                .foregroundStyle(.primary)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(NSLocalizedString("Reasoning effort for this model", comment: ""))
    }

    /// Access mode sits on the composer's left, next to "+", like Codex.
    /// It writes real session permission rules, so the label always reflects
    /// what the server will actually do with the next tool call.
    private var composerAccessMenu: some View {
        Menu {
            ForEach(SessionAccessMode.allCases) { mode in
                Button {
                    Task { await store.setAccessMode(mode) }
                } label: {
                    if store.accessMode == mode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }
            }
        } label: {
            Text(store.accessMode.shortLabel)
                .lineLimit(1)
                .font(.system(size: ChatTypography.meta(chatFontSize)))
                .foregroundStyle(store.accessMode == .allowAll ? Color.orange : Color.secondary)
                .padding(.vertical, 3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(store.selectedSessionID == nil)
        .help(store.accessMode.help)
    }

    private var composerSendButton: some View {
        Button {
            if store.isSending {
                store.abort()
            } else {
                store.send()
            }
        } label: {
            Image(systemName: store.isSending ? "stop.fill" : "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(
                    store.isSending
                        ? Color.white
                        : Color(nsColor: .textBackgroundColor)
                )
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(
                        store.isSending
                            ? Color.red.opacity(0.9)
                            : Color.primary.opacity(canSend ? 1 : 0.32)
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 8)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canSend && !store.isSending)
        .help(store.isSending
              ? NSLocalizedString("Stop generating", comment: "")
              : NSLocalizedString("Send message", comment: ""))
    }

    /// Floating pill shown while the user is reading history: jumps back to
    /// the tail and resumes stream following.
    private func backToLatestButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            isNearBottom = true
            withAnimation(.easeOut(duration: 0.2)) {
                if let last = store.messages.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        } label: {
            Label(NSLocalizedString("Back to latest", comment: ""), systemImage: "arrow.down.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.blue)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.blue.opacity(0.45)))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .padding(.bottom, 14 + queuedPromptsInset)
        .help(NSLocalizedString("Back to latest", comment: ""))
    }

    /// The queue strip sits between the transcript and the composer, outside
    /// the ScrollView. Lift the floating pill by the strip's height so the two
    /// never overlap.
    private var queuedPromptsInset: CGFloat {
        guard !store.queuedPrompts.isEmpty else { return 0 }
        // Measured instead of assuming a row height: long attachment labels
        // and font-size changes made a hard-coded 34pt drift out of sync.
        return queuedStripHeight
    }

    private var sessionArea: some View {
        VStack(spacing: 0) {
            if store.needsConsent {
                ConsentCard(
                    agreement: store.productAgreement,
                    isAccepting: store.isAcceptingConsent,
                    onAccept: {
                        Task { await store.acceptConsent() }
                    }
                )
                Divider()
            }

            if !store.todos.isEmpty {
                TodoPanel(todos: store.todos)
                Divider()
            }

            if let session = store.selectedSession, session.isReverted {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.orange)
                    Text(NSLocalizedString("Session is reverted to an earlier message; new prompts continue from there.", comment: ""))
                        .font(.caption)
                    Spacer()
                    Button(NSLocalizedString("Unrevert", comment: "")) {
                        Task { await store.unrevert() }
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.bannerWarning)
                Divider()
            }

            if store.isSending || store.retryInfo != nil {
                // Periodic tick re-evaluates the stalled hint; the ActivityBar
                // is the single generation indicator (composer keeps a mini one).
                TimelineView(.periodic(from: .now, by: 5)) { _ in
                    ActivityBar(
                        tool: runningTool,
                        todoProgress: store.todos.isEmpty ? nil : "\(store.todos.filter(\.isDone).count)/\(store.todos.count)",
                        retryInfo: store.retryInfo,
                        isThinking: runningTool == nil,
                        stalled: Date().timeIntervalSince(store.lastStreamActivity) > 60
                    ) {
                        store.abort()
                    }
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if store.isLoadingMessages && store.messages.isEmpty && searchQuery.isEmpty {
                            VStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(NSLocalizedString("Loading conversation…", comment: ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                        } else if store.messages.isEmpty && searchQuery.isEmpty {
                            newConversationState
                        } else {
                            // The hover strip now lives inside each message
                            // row, so the inter-message gap is reduced by the
                            // strip's height to keep the visual rhythm.
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(messageRows, id: \.message.id) { row in
                                    messageRowView(row)
                                }
                                if !searchQuery.isEmpty && visibleMessages.isEmpty {
                                    Text(String(format: NSLocalizedString("No messages match “%@”", comment: ""), searchQuery))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                // Failures belong to the turn that failed, so
                                // they render at the tail of the transcript
                                // (Codex-style) instead of a full-width strip.
                                if let error = store.inlineError,
                                   error.sessionID == store.selectedSessionID,
                                   searchQuery.isEmpty {
                                    InlineErrorBubble(error: error) {
                                        store.retryLastPrompt()
                                    }
                                    .id(Self.inlineErrorAnchor)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 26)
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .background(ScrollTracker { near, fits in
                        isNearBottom = near
                        transcriptFitsViewport = fits
                    })
                    .background(ScrollProgressTracker { progress in
                        transcriptScrollProgress = progress
                    })
                }
                .coordinateSpace(name: "chatScroll")
                .overlay(alignment: .bottom) {
                    if !isNearBottom, !transcriptFitsViewport, !store.messages.isEmpty, searchQuery.isEmpty {
                        backToLatestButton(proxy)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .overlay(alignment: .trailing) {
                    if !transcriptFitsViewport, !visibleMessages.isEmpty, searchQuery.isEmpty {
                        transcriptOverview(proxy)
                            .padding(.trailing, 8)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: isNearBottom)
                .onChange(of: store.streamTick) { _ in
                    guard isNearBottom, !transcriptFitsViewport, autoScroll,
                          searchQuery.isEmpty, let last = store.messages.last?.id else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
                .onChange(of: store.messages.count) { _ in
                    guard isNearBottom, !transcriptFitsViewport, autoScroll,
                          searchQuery.isEmpty, let last = store.messages.last?.id else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
                .onChange(of: store.inlineError?.id) { errorID in
                    guard errorID != nil, searchQuery.isEmpty else { return }
                    isNearBottom = true
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.inlineErrorAnchor, anchor: .bottom)
                    }
                }
                .onChange(of: searchQuery) { query in
                    // Jump to the first matching message when searching.
                    searchMatchIndex = 0
                    guard !query.isEmpty,
                          let first = store.messages.first(where: {
                              $0.parts.contains { ($0.text ?? "").localizedCaseInsensitiveContains(query) }
                          }) else { return }
                    proxy.scrollTo(first.id, anchor: .top)
                }
                .onChange(of: visibleMessages.count) { count in
                    // Streaming can remove the message the index pointed at
                    // (or the match set can shrink), leaving the "n/m" label
                    // and the jump target out of range.
                    if count == 0 {
                        searchMatchIndex = 0
                    } else if searchMatchIndex >= count {
                        searchMatchIndex = count - 1
                    }
                }
                .onChange(of: searchJumpTick) { _ in
                    guard searchMatchIndex < visibleMessages.count else { return }
                    proxy.scrollTo(visibleMessages[searchMatchIndex].id, anchor: .center)
                }
                .onReceive(NotificationCenter.default.publisher(for: .scrollTranscriptToTop)) { _ in
                    guard let first = store.messages.first?.id else { return }
                    isNearBottom = false
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(first, anchor: .top)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .scrollTranscriptToBottom)) { _ in
                    guard let last = store.messages.last?.id else { return }
                    isNearBottom = true
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }

            if !store.queuedPrompts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.queuedPrompts) { queued in
                        HStack(spacing: 8) {
                            Image(systemName: "clock")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(queued.text)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !queued.attachments.isEmpty {
                                Label("\(queued.attachments.count)", systemImage: "paperclip")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                                    .help(NSLocalizedString("Queued attachments", comment: ""))
                            }
                            Spacer(minLength: 6)
                            // Reorder inline: a second control row used to make
                            // every queued prompt two lines tall.
                            Button {
                                store.moveQueuedUp(queued.id)
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .disabled(store.queuedPrompts.first?.id == queued.id)
                            Button {
                                store.moveQueuedDown(queued.id)
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .disabled(store.queuedPrompts.last?.id == queued.id)
                            Button {
                                store.editQueued(queued)
                                focusTrigger += 1
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .help(NSLocalizedString("Edit queued prompt", comment: ""))
                            Button {
                                Task { await store.sendQueuedNow(queued) }
                            } label: {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .help(NSLocalizedString("Send now — stops the current generation", comment: ""))
                            Button {
                                store.removeQueued(queued)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .help(NSLocalizedString("Remove queued prompt", comment: ""))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
                .padding(.bottom, 2)
                .frame(maxWidth: contentMaxWidth, alignment: .leading)
                // Keep the strip at its natural height: without this the
                // flexible ScrollView above squeezes it and the composer
                // clips the row in half.
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: QueuedStripHeightKey.self, value: geo.size.height)
                    }
                )
            }

            // Asks and approvals sit next to the composer, where the user is
            // already looking; at the top of the transcript they were easy to
            // miss and pushed the conversation down when they appeared.
            if !store.pendingPermissions.isEmpty || !store.pendingQuestions.isEmpty {
                VStack(spacing: 8) {
                    if let request = store.pendingPermissions.first(where: { $0.sessionID == store.selectedSessionID }) {
                        let pendingCount = store.pendingPermissions.filter {
                            $0.sessionID == store.selectedSessionID
                        }.count
                        PermissionCardView(request: request, pendingCount: pendingCount)
                    }
                    if let request = store.pendingQuestions.first(where: { $0.sessionID == store.selectedSessionID }) {
                        QuestionBanner(request: request)
                            // A new ask must not inherit the previous card's
                            // picks: `selections` is keyed by question index,
                            // so without a fresh identity the next request
                            // looked pre-answered and could be submitted with
                            // stale choices.
                            .id(request.id)
                    }
                }
                // Match the composer's column: a full-bleed card across the
                // whole window read as a broken layout.
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 2)
            }

            VStack(spacing: 8) {
                if mentionToken != nil {
                    FileMentionView(
                        results: mentionMatches,
                        query: mentionToken ?? "",
                        selectedIndex: mentionIndex
                    ) { entry in
                        attachMention(entry)
                    }
                } else if !commandMatches.isEmpty {
                    CommandPaletteView(commands: commandMatches, selectedIndex: paletteIndex) { command in
                        applyCompletion(command)
                    }
                }
                if let warning = contextWarning {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                        Text(warning)
                            .font(.system(size: 12))
                        Spacer(minLength: 0)
                        Button(NSLocalizedString("Compact", comment: "compact conversation button")) {
                            Task { await store.compact() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .disabled(store.isCompacting || store.isSending)
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                }
                VStack(spacing: 0) {
                    if !store.attachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(store.attachments) { attachment in
                                    if let thumb = attachment.thumbnail, let image = NSImage(data: thumb) {
                                        ZStack(alignment: .topTrailing) {
                                            Image(nsImage: image)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 64, height: 64)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(Theme.softStroke)
                                                )
                                            Button {
                                                store.removeAttachment(attachment)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.system(size: 14))
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(.white, .black.opacity(0.65))
                                            }
                                            .buttonStyle(.plain)
                                            .padding(3)
                                        }
                                        .help(attachment.filename ?? NSLocalizedString("image", comment: "attachment fallback"))
                                    } else {
                                        HStack(spacing: 6) {
                                            Image(systemName: attachment.mime.hasPrefix("image/") ? "photo" : "doc")
                                                .font(.caption)
                                                .foregroundStyle(Color.accentColor)
                                            Text(attachment.filename ?? (attachment.mime.hasPrefix("image/")
                                                 ? NSLocalizedString("image", comment: "attachment fallback")
                                                 : NSLocalizedString("file", comment: "attachment fallback")))
                                                .font(.system(size: 12))
                                                .lineLimit(1)
                                            Button {
                                                store.removeAttachment(attachment)
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(Theme.chipFill)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                        }
                    }

                    ChatInput(text: $store.draft, enterSends: sendOnEnter,
                              fontSize: chatFontSize,
                              focusTrigger: focusTrigger,
                              draftToken: store.draftToken,
                              placeholder: NSLocalizedString("Write a message…", comment: ""),
                              onHistoryUp: historyUp, onHistoryDown: historyDown,
                              onArrowUp: handlePaletteUp, onArrowDown: handlePaletteDown,
                              onTab: handlePaletteTab,
                              onReturn: handlePaletteReturn,
                              onPasteImage: { data in store.addImageAttachment(data: data) },
                              onPasteFileURLs: { urls in addPastedFiles(urls) },
                              onDragHover: { dragHover = $0 },
                              onEscape: handleEscape,
                              onContentHeight: { inputHeight = $0 },
                              onSend: {
                                  suppressFocusOnce = true
                                  store.send()
                              })
                        .frame(height: inputHeight)
                        .padding(.horizontal, 12)
                        .padding(.top, 7)

                    HStack(spacing: 8) {
                        Button {
                            chooseAttachments()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .regular))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(store.selectedSessionID == nil)
                        .help(NSLocalizedString("Attach files from the project", comment: ""))

                        composerAccessMenu

                        if let usage = contextUsage {
                            ContextMeter(used: usage.used, limit: usage.limit, tokens: usage.tokens)
                        }
                        Spacer(minLength: 8)
                        composerModelMenu
                        if !effortVariants.isEmpty {
                            composerEffortMenu
                        }
                        composerSendButton
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 9)
                    .padding(.top, 1)
                    .padding(.bottom, 8)
                }
                .background(Theme.composerFill)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(dragHover ? Color.accentColor : Theme.softStroke, lineWidth: dragHover ? 2 : 1)
                )
                .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .help(sendOnEnter
                      ? NSLocalizedString("Enter sends · Shift+Enter newline · ⌘⏎ sends · / for commands", comment: "")
                      : NSLocalizedString("⌘⏎ sends · / for commands", comment: ""))
            }
        }
        .onPreferenceChange(QueuedStripHeightKey.self) { height in
            queuedStripHeight = height
        }
        .onChange(of: store.draft) { _ in
            paletteIndex = 0
            mentionIndex = 0
            updateMentionResults()
            if suppressFocusOnce {
                suppressFocusOnce = false
            } else if !store.isSending {
                focusTrigger += 1
            }
        }
        .onChange(of: store.selectedSessionID) { _ in
            isNearBottom = true
                    transcriptScrollProgress = 1
            searchQuery = ""
            showSearch = false
            focusTrigger += 1
        }
        .onChange(of: showSearch) { isOpen in
            if !isOpen {
                searchQuery = ""
                searchMatchIndex = 0
                searchFocused = false
            } else {
                DispatchQueue.main.async { searchFocused = true }
            }
        }
    }
}
extension ChatView {
    private func transcriptOverview(_ proxy: ScrollViewProxy) -> some View {
        TranscriptOverview(
            messageCount: visibleMessages.count,
            progress: transcriptScrollProgress
        ) { progress in
            guard !visibleMessages.isEmpty else { return }
            let index = Int((progress * CGFloat(visibleMessages.count - 1)).rounded())
            proxy.scrollTo(visibleMessages[min(max(0, index), visibleMessages.count - 1)].id, anchor: .top)
        }
    }
}
