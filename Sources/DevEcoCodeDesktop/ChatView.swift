import SwiftUI
import AppKit

private struct ModelGroup: Identifiable {
    let provider: String
    let choices: [ModelChoice]

    var id: String { provider }
}

/// Measured height of the queued-prompt strip, so the floating "Back to
/// latest" pill can clear it without hard-coding a per-row height.
private struct QueuedStripHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ChatView: View {
    @Binding var workPanelOpen: Bool
    @Binding var showSearch: Bool
    @Binding var section: AppSection

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
    /// True when the transcript is shorter than the viewport. Auto-scroll is
    /// pointless then, and `scrollTo(anchor: .bottom)` overscrolls such short
    /// transcripts so the first message gets clipped under the top row.
    @State private var transcriptFitsViewport = false

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

    private func historyDown() {
        let history = AppSettings.promptHistory
        guard let current = historyIndex else { return }
        let oldDraft = store.draft
        if current == 0 {
            historyIndex = nil
            store.draft = draftBeforeHistory
        } else {
            historyIndex = current - 1
            let index = min(current - 1, max(history.count - 1, 0))
            store.draft = history[history.count - 1 - index]
        }
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
                TranscriptToolbarActions(
                    showSearch: $showSearch,
                    workPanelOpen: $workPanelOpen
                )
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

    /// Conversation filter for ⌘F search.
    private var visibleMessages: [MessageRecord] {
        guard !searchQuery.isEmpty else { return store.messages }
        return store.messages.filter { message in
            message.parts.contains {
                ($0.text ?? "").localizedCaseInsensitiveContains(searchQuery)
            }
        }
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

    private func providerColor(_ provider: String) -> Color {
        let palette: [Color] = [.orange, .blue, .purple, .green, .teal, .pink]
        let seed = provider.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[seed % palette.count]
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

    /// Composer model picker: a popover with type-to-filter (64+ models make
    /// a nested menu painful) and a "recent" section fed by explicit picks.
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
        .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
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
                if !modelQuery.isEmpty {
                    Button { modelQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    modelPickerRow(id: nil, name: serverDefaultMenuLabel, provider: nil) {
                        pickModel(nil)
                    }
                    if modelQuery.isEmpty, !AppSettings.recentModels.isEmpty {
                        pickerSectionHeader(NSLocalizedString("Recent", comment: "model picker"))
                        ForEach(recentModelChoices) { choice in
                            modelPickerRow(id: choice.id, name: choice.name, provider: choice.provider) {
                                pickModel(choice.id)
                            }
                        }
                        pickerSectionHeader(NSLocalizedString("All models", comment: "model picker"))
                    }
                    ForEach(filteredModelGroups) { group in
                        pickerSectionHeader(group.provider)
                        ForEach(group.choices) { choice in
                            modelPickerRow(id: choice.id, name: choice.name, provider: choice.provider) {
                                pickModel(choice.id)
                            }
                        }
                    }
                    if filteredModelGroups.isEmpty && recentModelChoices.isEmpty {
                        Text("No models match “\(modelQuery)”")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(12)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 360, height: 380)
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
                Circle()
                    .fill(provider.map(providerColor) ?? Color.secondary)
                    .frame(width: 6, height: 6)
                Text(name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if id == store.selectedModel {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
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
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.softStroke))
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
                .padding(.horizontal, 22)
                .padding(.top, 6)
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
                                ForEach(visibleMessages) { message in
                                    MessageBubble(
                                        message: message,
                                        isStreaming: store.isSending && message.id == store.messages.last?.id,
                                        searchQuery: searchQuery
                                    )
                                    .id(message.id)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                                }
                                if !searchQuery.isEmpty && visibleMessages.isEmpty {
                                    Text("No messages match “\(searchQuery)”")
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
                            .animation(.easeOut(duration: 0.18), value: store.messages.count)
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
                }
                .coordinateSpace(name: "chatScroll")
                .overlay(alignment: .bottom) {
                    if !isNearBottom, !store.messages.isEmpty, searchQuery.isEmpty {
                        backToLatestButton(proxy)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
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
                                    HStack(spacing: 6) {
                                        if let thumb = attachment.thumbnail, let image = NSImage(data: thumb) {
                                            Image(nsImage: image)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 20, height: 20)
                                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                        } else {
                                            Image(systemName: attachment.mime.hasPrefix("image/") ? "photo" : "doc")
                                                .font(.caption)
                                                .foregroundStyle(Color.accentColor)
                                        }
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

/// Tracks whether the conversation sits near the bottom of the scroll view.
/// SwiftUI's ScrollView is NSScrollView-backed on macOS, so the tracker sits
/// as a background of the scrolled content and observes the enclosing clip
/// view's bounds changes directly — reliable even with a lazy stack whose
/// tail views are virtualized away.
private struct ScrollTracker: NSViewRepresentable {
    /// (nearBottom, contentFitsViewport)
    var onNearBottom: (Bool, Bool) -> Void

    func makeNSView(context: Context) -> TrackerView {
        let view = TrackerView()
        view.onNearBottom = onNearBottom
        return view
    }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.onNearBottom = onNearBottom
        view.report()
    }

    final class TrackerView: NSView {
        var onNearBottom: ((Bool, Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private static let threshold: CGFloat = 80
        private var lastContentHeight: CGFloat = 0
        /// Whether the transcript was pinned to the tail before the current
        /// layout pass. Content growth (streamed text, a footer that appears
        /// after usage lands) must not be mistaken for the user scrolling up.
        private var wasNearBottom = true

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            guard window != nil, let scroll = enclosingScrollView else { return }
            let clip = scroll.contentView
            clip.postsBoundsChangedNotifications = true
            scroll.documentView?.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.report() })
            observers.append(center.addObserver(
                forName: NSView.frameDidChangeNotification, object: scroll.documentView, queue: .main
            ) { [weak self] _ in self?.report() })
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        func report() {
            guard let scroll = enclosingScrollView,
                  let document = scroll.documentView,
                  let onNearBottom else { return }
            let clip = scroll.contentView.bounds
            let distance = document.bounds.height - clip.origin.y - clip.height
            let fits = document.bounds.height <= clip.height + 1
            let grew = document.bounds.height > lastContentHeight + 0.5
            lastContentHeight = document.bounds.height
            var near = distance <= Self.threshold || fits
            // Keep following the tail while the transcript grows. Without this
            // the final footer (rendered a beat after the last delta) pushes
            // the content down and leaves the reply clipped by the composer.
            if grew, wasNearBottom, !fits, NSEvent.pressedMouseButtons == 0 {
                let target = max(0, document.bounds.height - clip.height)
                scroll.contentView.scroll(to: NSPoint(x: clip.origin.x, y: target))
                scroll.reflectScrolledClipView(scroll.contentView)
                near = true
            }
            // A previous `scrollTo(bottom:)` can leave a short transcript
            // parked a few points above its natural top, which eats the top
            // padding. With nothing to scroll, the only valid offset is zero.
            if fits, clip.origin.y != 0 {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            wasNearBottom = near
            onNearBottom(near, fits)
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}

/// Slim sticky bar above the transcript, visible while the agent works even
/// when the user has scrolled away from the tail: current tool, todo
/// progress, and retry state in one line.
private struct ActivityBar: View {
    let tool: Part?
    let todoProgress: String?
    let retryInfo: String?
    /// True when a run is active but no delta arrived for over a minute.
    var stalled: Bool = false
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            if let tool {
                Image(systemName: "hammer")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                Text(Theme.toolName(tool.tool))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if let summary = tool.state?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                Text(NSLocalizedString("Working…", comment: ""))
                    .font(.system(size: 14, weight: .semibold))
            }
            if let todoProgress {
                Label(todoProgress, systemImage: "checklist")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if let retryInfo, !retryInfo.isEmpty {
                Label(retryInfo, systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if stalled {
                Text(NSLocalizedString("No output for over a minute — press Esc to stop.", comment: ""))
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Stop generating", comment: ""))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Theme.chromeFill)
    }
}

private struct StarterPromptButton: View {
    let systemImage: String
    let title: String
    let detail: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12))
                    .foregroundStyle(hovered ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? Color.accentColor.opacity(0.07) : Theme.cardFill)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(hovered ? Color.accentColor.opacity(0.28) : Theme.softStroke)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Multiline input backed by NSTextView so Enter can send and Shift+Enter can
/// insert a newline (a no-modifier keyboardShortcut on a Button is inert on
/// macOS, and TextEditor swallows Return).
private struct ChatInput: NSViewRepresentable {
    @Binding var text: String
    var enterSends: Bool
    var fontSize: Double
    var focusTrigger: Int
    var draftToken: UUID
    var placeholder: String
    var onHistoryUp: () -> Void
    var onHistoryDown: () -> Void
    var onArrowUp: () -> Bool
    var onArrowDown: () -> Bool
    var onTab: () -> Bool
    var onReturn: () -> Bool
    var onPasteImage: (Data) -> Void
    var onPasteFileURLs: ([URL]) -> Void
    var onDragHover: (Bool) -> Void
    var onEscape: () -> Void
    var onContentHeight: (CGFloat) -> Void
    var onSend: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onTextChange: ((String) -> Void)?
        var onSend: (() -> Void)?
        /// Token of the binding value last installed into the text view.
        /// A changed token means code replaced the draft (send / switch /
        /// history / edit), while an unchanged token with a different string
        /// is only a stale render of the user's own keystrokes.
        var lastSyncedToken: UUID?
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onTextChange?(textView.string)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let textView = ChatTextView.make(
            frame: NSRect(x: 0, y: 0, width: 480, height: 52)
        )
        textView.string = text
        coordinator.lastSyncedToken = draftToken
        textView.isRichText = false
        textView.placeholder = placeholder
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: ChatTypography.body(fontSize))
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 480,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 52)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.delegate = coordinator
        textView.onSend = {
            textView.isSendInFlight = true
            coordinator.onSend?()
        }
        textView.onContentHeight = onContentHeight
        textView.onPasteImage = onPasteImage
        textView.onPasteFileURLs = onPasteFileURLs
        textView.onDragHover = onDragHover

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        DispatchQueue.main.async { [weak textView] in
            if let textView { textView.reportHeight() }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onTextChange = { text = $0 }
        coordinator.onSend = onSend
        guard let textView = scroll.documentView as? ChatTextView else { return }
        // Keep the drawing-only placeholder in sync. Never assign to
        // `textView.string` here: that mutates the text storage, fires
        // textDidChange, and can feed "Write a message…" back into the draft.
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
        }
        let width = max(scroll.contentSize.width, 1)
        if abs(textView.frame.width - width) > 0.5 {
            var frame = textView.frame
            frame.size.width = width
            textView.frame = frame
            textView.textContainer?.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        textView.enterSends = enterSends
        let resolvedFont = NSFont.systemFont(
            ofSize: ChatTypography.body(fontSize)
        )
        if textView.font != resolvedFont {
            textView.font = resolvedFont
            DispatchQueue.main.async { [weak textView] in
                textView?.reportHeight()
            }
        }
        textView.onHistoryUp = onHistoryUp
        textView.onHistoryDown = onHistoryDown
        textView.onArrowUp = onArrowUp
        textView.onArrowDown = onArrowDown
        textView.onTab = onTab
        textView.onReturn = onReturn
        textView.onEscape = onEscape
        textView.onDragHover = onDragHover
        textView.onContentHeight = onContentHeight
        if textView.lastFocusTrigger != focusTrigger {
            textView.lastFocusTrigger = focusTrigger
            DispatchQueue.main.async { [weak textView] in
                textView?.window?.makeFirstResponder(textView)
            }
        }
        if textView.string != text {
            // Code-driven replacement (send / switch / history / edit) always
            // wins — including the clear after send. If the token is the same
            // the difference is just a stale render of user typing, which we
            // never overwrite mid-keystroke or during IME composition.
            if !textView.hasMarkedText() {
                if coordinator.lastSyncedToken != draftToken {
                    textView.string = text
                    coordinator.lastSyncedToken = draftToken
                    textView.isSendInFlight = false
                } else {
                    // The binding caught up to the user's own typing. Keep
                    // the token in sync without touching the text storage.
                    coordinator.lastSyncedToken = draftToken
                }
            }
            // Report outside the view update — mutating state here would be
            // discarded by SwiftUI.
            DispatchQueue.main.async { [weak textView] in
                textView?.reportHeight()
            }
        }
    }
}

private final class ChatTextView: NSTextView {
    var onSend: (() -> Void)?
    var onHistoryUp: (() -> Void)?
    var onHistoryDown: (() -> Void)?
    var onArrowUp: (() -> Bool)?
    var onArrowDown: (() -> Bool)?
    var onTab: (() -> Bool)?
    var onReturn: (() -> Bool)?
    var onPasteImage: ((Data) -> Void)?
    var onPasteFileURLs: (([URL]) -> Void)?
    var onDragHover: ((Bool) -> Void)?
    var onEscape: (() -> Void)?
    var onContentHeight: ((CGFloat) -> Void)?
        var placeholder = ""
    var enterSends = true
    var lastFocusTrigger = -1
    /// Set while a send is in flight. Enter during this window would
    /// otherwise flush text typed after send() cleared the draft — the race
    /// that merged two messages into one. Cleared on the next text change.
    var isSendInFlight = false

    /// `init(frame:textContainer:)` does not build a text system when the
    /// container is nil; create storage + layout manager + container here.
    static func make(frame: NSRect) -> ChatTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        return ChatTextView(frame: frame, textContainer: container)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .string])
    }

    override func insertNewline(_ sender: Any?) {
        // Let the input method finish composition (e.g. Chinese IME
        // candidates); intercepting that Enter would send mid-word.
        if hasMarkedText() {
            super.insertNewline(sender)
            return
        }
        // A send just cleared the composer; any text on screen now was typed
        // after that send and must not be flushed by the same Enter press.
        if isSendInFlight && !string.isEmpty {
            isSendInFlight = false
            return
        }
        let hasShift = NSApp.currentEvent?.modifierFlags.contains(.shift)
            ?? NSApplication.shared.currentEvent?.modifierFlags.contains(.shift)
            ?? false
        if enterSends && !hasShift {
            // A visible candidate list wins: Enter completes, a second Enter
            // (popup now closed) sends.
            if onReturn?() != true {
                onSend?()
            }
        } else {
            super.insertNewline(sender)
        }
    }

    func reportHeight() {
        guard let onContentHeight, let layoutManager, let textContainer else { return }
        let used = layoutManager.usedRect(for: textContainer).height
        let total = used + textContainerInset.height * 2 + 6
        let height = max(52, min(160, ceil(total)))
        if abs(frame.height - height) > 0.5 {
            var next = frame
            next.size.height = height
            frame = next
        }
        onContentHeight(height)
    }

    override func didChangeText() {
        super.didChangeText()
        isSendInFlight = false
        reportHeight()
    }

    /// Placeholder drawn inside the view so it hides while IME marked text
    /// (composition) is on screen — a SwiftUI overlay cannot observe that.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        NSAttributedString(string: placeholder, attributes: attributes).draw(
            at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height - 3)
        )
    }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        // Screenshot tools and copied images land here.
        if let image = NSImage(pasteboard: board),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            onPasteImage?(png)
            return
        }
        // Files copied in Finder attach by reference.
        if let urls = board.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onPasteFileURLs?(urls)
            return
        }
        super.paste(sender)
    }

    // Drag files onto the input to attach them (same channel as paste).
    // The hover callbacks drive the composer's accent-border highlight.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.types?.contains(.fileURL) == true {
            onDragHover?(true)
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragHover?(false)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragHover?(false)
        super.draggingEnded(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragHover?(false)
        if let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            onPasteFileURLs?(urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    override func keyDown(with event: NSEvent) {
        // A marked-text session means an IME candidate window is open. Esc
        // must close the candidates (not abort the run), and arrow keys must
        // move the candidate selection instead of recalling prompt history.
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        let hasOption = event.modifierFlags.contains(.option)
        let isUp = event.specialKey == .upArrow || event.keyCode == 126
        let isDown = event.specialKey == .downArrow || event.keyCode == 125
        let isTab = event.specialKey == .tab || event.keyCode == 48
        if hasOption && isUp {
            onHistoryUp?()
            return
        }
        if hasOption && isDown {
            onHistoryDown?()
            return
        }
        if isUp, let up = onArrowUp, up() { return }
        if isDown, let down = onArrowDown, down() { return }
        if isTab, let tab = onTab, tab() { return }
        if event.keyCode == 53, let onEscape { onEscape(); return } // Escape 不在 SpecialKey 中
        super.keyDown(with: event)
    }
}

private struct MessageBubble: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var providers: ProviderStore
    let message: MessageRecord
    /// 由父视图显式传入：仅正在流式输出的最后一条为 true。
    /// 避免每个气泡都读 store.isSending/messages.last 导致全量重算。
    var isStreaming: Bool = false
    var searchQuery: String = ""

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
                ForEach(message.parts) { part in
                    PartView(
                        part: part,
                        useMarkdown: true,
                        isStreaming: isStreamingThis,
                        searchQuery: searchQuery
                    )
                }

                HStack(spacing: 6) {
                    if let elapsed = message.info.elapsedDuration {
                        Text(elapsed)
                            .font(.system(size: microSize))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    if let metadata = assistantFooterMetadata {
                        Text(metadata)
                            .font(.system(size: microSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .font(.system(size: ChatTypography.body(chatFontSize)))
            .lineSpacing(ChatTypography.lineSpacing(chatFontSize))
            .padding(.vertical, 3)

            hoverActionRow
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

private struct TodoPanel: View {
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

    private var content: String {
        StreamRenderText.liveTailText(split, showCaret: isTypewriterActive)
    }

    /// A bubble is live only while the server is appending or the typewriter
    /// is still catching up. The split renderer keeps the last line as plain
    /// text so half-written markup cannot repaint the bubble; a finished reply
    /// must go through the full Markdown path or inline styling on its final
    /// line (bold, code spans, links) would render as literal markers.
    private var isLive: Bool {
        isStreaming || isTypewriterActive
    }

    /// User-authored text must stay verbatim: running it through the Markdown
    /// renderer turned "# heading" into a heading and ``` fences into code
    /// cards, so what the user typed no longer matched what they sent.
    private var plainContent: String {
        isTypewriterActive ? shown + "▍" : shown
    }

    private var split: StreamRenderText.Split {
        StreamRenderText.displaySplit(shown, isLive: isLive)
    }

    var body: some View {
        Group {
            if useMarkdown {
                VStack(alignment: .leading, spacing: 0) {
                    if split.hasStablePrefix {
                        MarkdownContentView(content: split.stablePrefix, searchQuery: searchQuery)
                    }
                    Text(content)
                        .font(.system(size: ChatTypography.body(chatFontSize)))
                        .lineSpacing(ChatTypography.lineSpacing(chatFontSize))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !searchQuery.isEmpty,
                      let attributed = highlightedAttributedString(plainContent, query: searchQuery) {
                Text(attributed)
                    .font(.system(size: ChatTypography.body(chatFontSize)))
                    .lineSpacing(ChatTypography.lineSpacing(chatFontSize))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(plainContent)
                    .font(.system(size: ChatTypography.body(chatFontSize)))
                    .lineSpacing(ChatTypography.lineSpacing(chatFontSize))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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

    private var target = ""
    private var displayedUnits = 0
    private var lastTick = Date.distantPast
    /// At most one queued tick. Without this, a burst of `update` calls could
    /// start several independent asyncAfter chains that all mutate `text`.
    private var tickScheduled = false
    /// Set only when the bubble has actually been in a live streaming state.
    private(set) var activated = false
    var finished: Bool { displayedUnits >= target.count }

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
        if newTarget.count < displayedUnits {
            // The server can rewrite a streaming part (a reverted tail, a
            // normalized prefix). Clamp to the new length instead of rewinding
            // to zero: the old code fell back to the 6-glyph seed and replayed
            // the whole visible answer, which read as a flash.
            displayedUnits = newTarget.count
            text = newTarget
        }
        target = newTarget
        guard activated else { return }
        if newStreaming && displayedUnits == 0 && !newTarget.isEmpty {
            displayedUnits = min(6, newTarget.count)
            text = String(newTarget.prefix(displayedUnits))
        }
        if !newStreaming && displayedUnits == 0 {
            displayedUnits = newTarget.count
            text = newTarget
            return
        }
        ensureTicking()
    }

    private func ensureTicking() {
        guard displayedUnits < target.count else {
            // Caught up with the transcript. Never rewind: a partial reveal
            // that shrinks while the server is still appending makes the tail
            // flicker (and can strand a lone caret glyph on its own line).
            text = target
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
        displayedUnits = min(target.count, displayedUnits + step)
        text = String(target.prefix(displayedUnits))
        if displayedUnits < target.count {
            scheduleTick(after: Self.minInterval)
        }
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

    @State private var thinkingExpanded: Bool

    init(part: Part, useMarkdown: Bool, isStreaming: Bool = false, searchQuery: String = "") {
        self.part = part
        self.useMarkdown = useMarkdown
        self.isStreaming = isStreaming
        self.searchQuery = searchQuery
        _thinkingExpanded = State(initialValue: AppSettings.expandThinking)
    }

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
            DisclosureGroup(isExpanded: $thinkingExpanded) {
                Text(part.text ?? "")
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

// MARK: - Markdown + code blocks

/// Attributed text with every occurrence of `query` highlighted. Used for
/// ⌘F in-message emphasis on plain-text (user) parts; nil = no matches.
func highlightedAttributedString(_ text: String, query: String) -> AttributedString? {
    guard !query.isEmpty, text.localizedCaseInsensitiveContains(query) else { return nil }
    var hits: [Range<String.Index>] = []
    var searchStart = text.startIndex
    while searchStart < text.endIndex,
          let hit = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
        hits.append(hit)
        searchStart = hit.upperBound
    }
    guard !hits.isEmpty else { return nil }
    var result = AttributedString()
    var cursor = text.startIndex
    for hit in hits {
        result += AttributedString(String(text[cursor..<hit.lowerBound]))
        var highlighted = AttributedString(String(text[hit]))
        highlighted.backgroundColor = Color.yellow.opacity(0.45)
        result += highlighted
        cursor = hit.upperBound
    }
    result += AttributedString(String(text[cursor...]))
    return result
}

enum MarkdownSegment: Equatable {
    case text(String)
    case code(lang: String, code: String)
}

/// Streaming re-renders every visible bubble on each delta flush; these
/// caches keep per-frame work proportional to the changed message instead of
/// the whole visible transcript.
private final class CachedBox<Value> {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private enum MarkdownCache {
    static let segments = NSCache<NSString, CachedBox<[MarkdownSegment]>>()
    static let proseBlocks = NSCache<NSString, CachedBox<[MarkdownProseBlock]>>()
    static let inline = NSCache<NSString, CachedBox<AttributedString>>()

    static func key(_ parts: String...) -> NSString {
        parts.joined(separator: "|") as NSString
    }
}

/// Test hooks: NSCache returns the same box object on a hit, so tests can
/// verify the cache contract without timing thresholds or private mirrors.
func markdownSegmentsCacheToken(for content: String) -> AnyObject? {
    MarkdownCache.segments.object(forKey: content as NSString)
}

func markdownProseBlocksCacheToken(for text: String) -> AnyObject? {
    MarkdownCache.proseBlocks.object(forKey: text as NSString)
}

/// Splits assistant output into prose and fenced code blocks. An unterminated
/// fence (mid-stream) renders its tail as code, so the block appears styled
/// immediately instead of flashing as plain text.
func parseMarkdownSegments(_ content: String) -> [MarkdownSegment] {
    let cacheKey = content as NSString
    if let cached = MarkdownCache.segments.object(forKey: cacheKey)?.value {
        return cached
    }
    var segments: [MarkdownSegment] = []
    var textLines: [String] = []
    var codeLines: [String] = []
    var currentLang = ""
    var inCode = false

    for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(line)
        if !inCode, line.hasPrefix("```") {
            if !textLines.isEmpty {
                segments.append(.text(textLines.joined(separator: "\n")))
                textLines = []
            }
            inCode = true
            currentLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            codeLines = []
        } else if inCode, line.hasPrefix("```") {
            segments.append(.code(lang: currentLang, code: codeLines.joined(separator: "\n")))
            inCode = false
            currentLang = ""
            codeLines = []
        } else if inCode {
            codeLines.append(line)
        } else {
            textLines.append(line)
        }
    }
    if inCode {
        segments.append(.code(lang: currentLang, code: codeLines.joined(separator: "\n")))
    } else if !textLines.isEmpty {
        segments.append(.text(textLines.joined(separator: "\n")))
    }
    MarkdownCache.segments.setObject(CachedBox(segments), forKey: cacheKey)
    return segments
}

enum MarkdownProseBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(String)
    case numbered(number: Int, text: String)
    case quote(String)
    case systemNotice(String)
    case divider
}

/// A narrow set of model-generated bookkeeping lines. They are not user prose
/// and should not inherit the answer's body typography. Keep this conservative:
/// unknown lines stay normal paragraphs.
private func isSystemNoticeLine(_ text: String) -> Bool {
    let lowered = text.lowercased()
    let markers = [
        "recalled ",
        "remembered ",
        "loaded skill ",
        "using skill ",
        "reading ",
        "searching ",
        "fetched ",
    ]
    guard markers.contains(where: { lowered.contains($0) }) else { return false }
    return lowered.contains("(") && lowered.contains(")")
}

/// Drops bookkeeping lines such as "💡 Recalled … (project)" while keeping
/// the real answer that follows them in the same text part.
func removingSystemNoticeLines(_ text: String) -> String {
    text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !isSystemNoticeLine(String($0.trimmingCharacters(in: .whitespaces))) }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Only assistant output carries model bookkeeping lines. User prompts are
/// verbatim: a prompt like "searching for X (in src)" must never be mistaken
/// for a notice and filtered down to an empty bubble.
func visiblePartText(_ text: String, useMarkdown: Bool) -> String {
    guard useMarkdown else {
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return removingSystemNoticeLines(text)
}

func systemNoticeText(_ text: String) -> String {
    text
        .replacingOccurrences(of: "💡 ", with: "")
        .replacingOccurrences(of: "# ", with: "")
}

/// Splits prose into headings, lists, quotes, and paragraphs. Inline styling
/// (bold/italic/inline code) is still delegated to AttributedString.
func parseMarkdownProseBlocks(_ text: String) -> [MarkdownProseBlock] {
    let cacheKey = text as NSString
    if let cached = MarkdownCache.proseBlocks.object(forKey: cacheKey)?.value {
        return cached
    }
    var blocks: [MarkdownProseBlock] = []
    var paragraphLines: [String] = []

    func flushParagraph() {
        let paragraph = paragraphLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !paragraph.isEmpty {
            blocks.append(.paragraph(paragraph))
        }
        paragraphLines = []
    }

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            flushParagraph()
            continue
        }
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            flushParagraph()
            blocks.append(.divider)
            continue
        }

        let hashes = trimmed.prefix(while: { $0 == "#" })
        if (1...6).contains(hashes.count) {
            let rest = trimmed.dropFirst(hashes.count)
            if rest.first?.isWhitespace == true {
                let heading = String(rest).trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty {
                    flushParagraph()
                    blocks.append(.heading(level: hashes.count, text: heading))
                    continue
                }
            }
        }

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            flushParagraph()
            blocks.append(.bullet(String(trimmed.dropFirst(2))))
            continue
        }

        let pieces = trimmed.split(separator: " ", maxSplits: 1)
        if pieces.count == 2 {
            let marker = pieces[0]
            let numeric = marker.dropLast()
            let validMarker = marker.hasSuffix(".") || marker.hasSuffix(")")
            if validMarker, let number = Int(numeric) {
                flushParagraph()
                blocks.append(.numbered(number: number, text: String(pieces[1])))
                continue
            }
        }

        if trimmed.hasPrefix(">") {
            flushParagraph()
            let quote = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            if !quote.isEmpty {
                blocks.append(.quote(quote))
            }
            continue
        }

        if isSystemNoticeLine(trimmed) { continue }

        paragraphLines.append(trimmed)
    }

    flushParagraph()
    MarkdownCache.proseBlocks.setObject(CachedBox(blocks), forKey: cacheKey)
    return blocks
}

/// Renders assistant prose with readable block formatting, and fenced blocks
/// as horizontally scrollable code cards.
struct MarkdownContentView: View {
    let content: String
    /// When set (⌘F active), prose segments highlight the matches.
    var searchQuery: String = ""

    var body: some View {
        let segments = parseMarkdownSegments(content)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    MarkdownProseView(text: text, highlightQuery: searchQuery)
                case .code(let lang, let code):
                    CodeBlockView(lang: lang, code: code)
                }
            }
        }
    }
}

private struct MarkdownProseView: View {
    let text: String
    var highlightQuery: String = ""

    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0

    private var bodySize: CGFloat {
        ChatTypography.body(chatFontSize)
    }

    private var blockSpacing: CGFloat {
        max(5, bodySize * 0.42)
    }

    var body: some View {
        let blocks = parseMarkdownProseBlocks(text)
        VStack(alignment: .leading, spacing: blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownProseBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inlineText(text, size: bodySize)
        case .heading(let level, let text):
            inlineText(
                text,
                size: ChatTypography.heading(chatFontSize, level: min(level, 3)),
                weight: .semibold
            )
            .padding(.top, level == 1 ? 3 : 1)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(.system(size: bodySize, weight: .semibold))
                    .foregroundStyle(.secondary)
                inlineText(text, size: bodySize)
            }
            .padding(.leading, 3)
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(number).")
                    .font(.system(size: bodySize, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: max(18, bodySize * 1.25), alignment: .trailing)
                inlineText(text, size: bodySize)
            }
        case .quote(let text):
            inlineText(text, size: bodySize)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .padding(.vertical, 2)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.35))
                        .frame(width: 2)
                }
        case .systemNotice:
            EmptyView()
        case .divider:
            Divider()
                .padding(.vertical, 2)
        }
    }

    private func inlineText(
        _ text: String,
        size: CGFloat,
        weight: Font.Weight = .regular
    ) -> some View {
        Group {
            if !highlightQuery.isEmpty,
               let highlighted = highlightedAttributedString(text, query: highlightQuery) {
                Text(highlighted)
            } else if let attributed = cachedInline(text, size: size, weight: weight) {
                Text(attributed)
            } else {
                Text(text)
            }
        }
        .font(.system(size: size, weight: weight))
        .lineSpacing(ChatTypography.lineSpacing(chatFontSize))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Identical paragraphs across renders hit the cache; only the streaming
    /// bubble's tail paragraph re-parses per flush.
    private func cachedInline(
        _ text: String,
        size: CGFloat,
        weight: Font.Weight
    ) -> AttributedString? {
        let key = MarkdownCache.key("\(size)", "\(weight)", text)
        if let cached = MarkdownCache.inline.object(forKey: key)?.value {
            return cached
        }
        guard var attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) else { return nil }
        styleInlineCode(&attributed)
        MarkdownCache.inline.setObject(CachedBox(attributed), forKey: key)
        return attributed
    }

    /// Codex-like inline richness: backticked tokens render on a subtle chip
    /// tint with monospaced digits — file names, flags, and code refs pop out
    /// of prose without switching to a full code block.
    private func styleInlineCode(_ attributed: inout AttributedString) {
        var styled = AttributedString()
        let runs = Array(attributed.runs)
        for run in runs {
            let range = run.range
            var chunk = AttributedString(attributed[range])
            if run.inlinePresentationIntent?.contains(.code) == true {
                chunk.font = .system(size: bodySize - 1.5, weight: .medium, design: .monospaced)
                chunk.foregroundColor = .accentColor
                chunk.backgroundColor = Color.accentColor.opacity(0.10)
            } else if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                chunk.font = .system(size: bodySize, weight: .bold)
                chunk.foregroundColor = .primary
            } else if run.inlinePresentationIntent?.contains(.emphasized) == true {
                chunk.font = .system(size: bodySize, weight: .regular, design: .serif)
                chunk.foregroundColor = .secondary
            }
            styled.append(chunk)
        }
        attributed = styled
    }
}

private struct CodeBlockView: View {
    let lang: String
    let code: String

    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0

    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? NSLocalizedString("code", comment: "code block fallback label") : lang)
                    .font(.system(size: ChatTypography.meta(chatFontSize), weight: .medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    copyCode()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: ChatTypography.meta(chatFontSize)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .help(NSLocalizedString("Copy code", comment: ""))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                Text(CodeHighlighter.highlight(code, language: lang))
                    .font(.system(
                        size: ChatTypography.code(chatFontSize),
                        weight: .regular,
                        design: .monospaced
                    ))
                    .lineSpacing(max(1, ChatTypography.lineSpacing(chatFontSize) * 0.35))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(10)
            }
        }
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.softStroke)
        )
        .onDisappear {
            copyResetTask?.cancel()
            copyResetTask = nil
        }
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

/// Composer token meter: Claude-style ring + numeric readout for the full
/// request context of the last turn vs. the selected model's limit. The arc
/// shifts from blue to orange to red as the window fills.
private struct ContextMeter: View {
    let used: Double
    let limit: Double?
    var tokens: MessageTokens?

    @State private var showDetails = false
    @State private var cursorPushed = false

    private var ratio: Double? {
        guard let limit, limit > 0 else { return nil }
        return min(max(used / limit, 0), 1)
    }

    private var tint: Color {
        guard let ratio else { return .secondary }
        if ratio > 0.85 { return .red }
        if ratio > 0.6 { return .orange }
        return .blue
    }

    var body: some View {
        HStack(spacing: 6) {
            if let limit, limit > 0, let ratio {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.14), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: max(ratio, 0.001))
                        .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
                .animation(.easeOut(duration: 0.3), value: ratio)
                Text("\(compactTokenCount(used)) / \(compactTokenCount(limit)) · \(Int((ratio * 100).rounded()))%")
                    .foregroundStyle(tint)
                    .monospacedDigit()
            } else {
                Text("\(compactTokenCount(used)) tokens")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .contentShape(Rectangle())
        .onTapGesture {
            showDetails.toggle()
        }
        .onHover { hovering in
            if hovering && !cursorPushed {
                NSCursor.pointingHand.push()
                cursorPushed = true
            } else if !hovering && cursorPushed {
                NSCursor.pointingHand.pop()
                cursorPushed = false
            }
        }
        .onDisappear {
            if cursorPushed {
                NSCursor.pointingHand.pop()
                cursorPushed = false
            }
        }
        .popover(isPresented: $showDetails, arrowEdge: .bottom) {
            ContextDetailsPopover(used: used, limit: limit, tokens: tokens)
        }
        .help(NSLocalizedString(
            "Context window usage — click for breakdown",
            comment: ""
        ))
    }
}

/// Claude-style context breakdown. The deveco server only reports aggregate
/// counters (input / cache.read / output), so those are shown honestly instead
/// of inventing system-prompt / tool splits the API does not expose.
private struct ContextDetailsPopover: View {
    let used: Double
    let limit: Double?
    let tokens: MessageTokens?

    private var inputTokens: Double { tokens?.input ?? 0 }
    private var cachedTokens: Double { tokens?.cache?.read ?? 0 }
    private var generatedTokens: Double {
        (tokens?.output ?? 0) + (tokens?.reasoning ?? 0)
    }
    private var freeSpace: Double {
        guard let limit, limit > 0 else { return 0 }
        return max(0, limit - used)
    }
    private var ratio: Double? {
        guard let limit, limit > 0 else { return nil }
        return min(max(used / limit, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(NSLocalizedString("Context window", comment: "context popover title"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let limit, limit > 0, let ratio {
                    Text("\(compactTokenCount(used)) / \(compactTokenCount(limit)) · \(Int((ratio * 100).rounded()))%")
                        .font(.system(size: 12, design: .monospaced))
                        .monospacedDigit()
                } else {
                    Text(compactTokenCount(used))
                        .font(.system(size: 12, design: .monospaced))
                }
            }
            if let limit, limit > 0, let ratio {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule()
                            .fill(ratio > 0.85 ? Color.red : (ratio > 0.6 ? Color.orange : Color.blue))
                            .frame(width: max(3, proxy.size.width * ratio))
                    }
                }
                .frame(height: 5)
            }
            Divider()
            row(color: .blue, label: NSLocalizedString("New input", comment: ""),
                amount: inputTokens, limit: limit)
            row(color: .orange, label: NSLocalizedString("Cached input", comment: ""),
                amount: cachedTokens, limit: limit)
            row(color: .purple, label: NSLocalizedString("Generated", comment: ""),
                amount: generatedTokens, limit: nil)
            row(color: .gray.opacity(0.5), label: NSLocalizedString("Free space", comment: ""),
                amount: freeSpace, limit: limit)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }

    private func row(color: Color, label: String, amount: Double, limit: Double?) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
            Spacer()
            Text(compactTokenCount(amount))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
            if let limit, limit > 0 {
                Text(String(format: "%.1f%%", amount / limit * 100))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

/// Decoded image cache — bubbles re-render on every stream flush, and
/// re-decoding a multi-MB screenshot each time would spike the CPU.
private enum ImageCache {
    static let cache = NSCache<NSString, NSImage>()

    /// Bounds decoded bitmaps. A screenshot that arrives as a 12MP data URL
    /// otherwise stays resident at full size for the whole session.
    static let maxPixelDimension: CGFloat = 2048

    static func decoded(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return NSImage(data: data)
        }
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maxPixelDimension else {
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        let scale = maxPixelDimension / longest
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { return nil }
        return NSImage(cgImage: resized, size: NSSize(width: width, height: height))
    }
}

/// File attachment from a prompt or an agent message. Images render inline
/// (data: and file: URLs both verified in stored traffic); other types show
/// as a chip. Clicking opens the content.
struct AttachmentChip: View {
    let filename: String
    let mime: String?
    let urlString: String?

    private var isImage: Bool {
        mime?.hasPrefix("image/") == true
    }

    var body: some View {
        if isImage, let image = loadImage() {
            VStack(alignment: .leading, spacing: 4) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.softStroke))
                if !filename.isEmpty {
                    Text(filename)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { open() }
            .help(NSLocalizedString("Open attachment", comment: ""))
        } else {
            chip
        }
    }

    private var chip: some View {
        Button {
            open()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.plaintext")
                    .foregroundStyle(Color.accentColor)
                Text(filename)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.chipFill)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.softStroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Open attachment", comment: ""))
    }

    private func loadImage() -> NSImage? {
        guard let urlString else { return nil }
        let key = urlString as NSString
        if let cached = ImageCache.cache.object(forKey: key) {
            return cached
        }
        let data: Data?
        if urlString.hasPrefix("data:"), let url = URL(string: urlString) {
            data = try? Data(contentsOf: url)
        } else if let url = URL(string: urlString), url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            data = nil
        }
        guard let data, let image = ImageCache.decoded(data) else { return nil }
        ImageCache.cache.setObject(image, forKey: key)
        return image
    }

    private func open() {
        guard let urlString else { return }
        if urlString.hasPrefix("data:") {
            // LaunchServices cannot open data URLs — materialize to a cache file.
            guard let url = URL(string: urlString), let data = try? Data(contentsOf: url),
                  let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
            let ext = mime == "image/jpeg" ? "jpg" : (mime == "image/gif" ? "gif" : "png")
            let fileURL = caches.appendingPathComponent("deveco-attachment-\(UUID().uuidString).\(ext)")
            try? data.write(to: fileURL)
            NSWorkspace.shared.open(fileURL)
            return
        }
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// deveco refuses model calls until its product agreement is accepted; this
/// card explains that and offers a one-click acceptance.
struct ConsentCard: View {
    let agreement: ProductAgreement?
    let isAccepting: Bool
    var onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.checkmark")
                    .foregroundStyle(.orange)
                Text(NSLocalizedString("Product agreement confirmation required", comment: ""))
                    .font(.headline)
            }
            Text(NSLocalizedString("Before any model can be called, deveco requires you to accept its product terms and privacy statement.", comment: ""))
                .font(.callout)
            if let terms = agreement?.termsUrl, let url = URL(string: terms) {
                Link("Read the terms", destination: url)
                    .font(.caption)
            }
            if let privacy = agreement?.privacyUrl, let url = URL(string: privacy) {
                Link("Read the privacy statement", destination: url)
                    .font(.caption)
            }
            HStack {
                Button {
                    onAccept()
                } label: {
                    if isAccepting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(NSLocalizedString("I have read and accept", comment: ""))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isAccepting)
                Text(NSLocalizedString("Equivalent to `deveco auth consent --accept`.", comment: ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Theme.bannerWarning)
    }
}

/// Expandable tool call card: header with status/duration, details reveal
/// input args, full output, and errors. The output text is already decoded
/// from ToolState and just was never surfaced before.
private struct TaskTraceCard: View {
    let part: Part
    /// Embedded inside a tool card: the outer card already draws the single
    /// container, so this variant must not add another border/background.
    var embedded = false
    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0
    @State private var expanded = false

    private var trace: ToolTrace { ToolTrace.parse(part.text ?? "") }

    private var headerTitle: String {
        if !trace.description.isEmpty { return trace.description }
        if !trace.prompt.isEmpty { return String(trace.prompt.prefix(60)) }
        return NSLocalizedString("Task", comment: "")
    }

    private var hasDetail: Bool {
        !trace.prompt.isEmpty || !trace.result.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: hasDetail && expanded ? 8 : 0) {
            Button {
                guard hasDetail else { return }
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20, height: 20)
                    Text(headerTitle)
                        .font(.system(size: ChatTypography.meta(chatFontSize), weight: .semibold))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let type = trace.subagentType {
                        Text(type)
                            .font(.system(size: ChatTypography.micro(chatFontSize), weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.10), in: Capsule())
                    }
                    Spacer(minLength: 8)
                    if hasDetail {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasDetail)

            if hasDetail && expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !trace.prompt.isEmpty {
                        traceSection(label: NSLocalizedString("Prompt", comment: ""), content: trace.prompt, tint: .accentColor)
                    }
                    if !trace.result.isEmpty {
                        traceSection(label: NSLocalizedString("Result", comment: ""), content: trace.result, tint: .green)
                    }
                }
                .padding(.bottom, 2)
            }
        }
    }

    /// Codex-style detail block: a tinted label and prose on a subtle surface,
    /// with no second stroke — nested boxes are what made the transcript busy.
    private func traceSection(label: String, content: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Rectangle().fill(tint).frame(width: 2, height: ChatTypography.micro(chatFontSize))
                Text(label)
                    .font(.system(size: ChatTypography.micro(chatFontSize), weight: .semibold))
                    .foregroundStyle(tint)
            }
            MarkdownContentView(content: content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct ToolCardView: View {
    let part: Part
    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0

    /// nil = follow the default policy (running tools expand, finished ones
    /// collapse); after the user toggles, their choice wins.
    @State private var userExpanded: Bool?

    private var state: ToolState? { part.state }

    private var isRunning: Bool { state?.status == "running" }
    private var isStopped: Bool {
        guard let error = state?.error else { return false }
        return FailureKind.classify(error) == .aborted
    }
    private var isError: Bool { state?.status == "error" && !isStopped }

    /// "The user dismissed this question" is a normal way to end a question
    /// tool; painting the card red and labeling it Error made the transcript
    /// look broken. Keep the dismiss note as neutral metadata.
    private var isQuestionDismissed: Bool {
        part.tool == "question"
            && state?.status == "error"
            && (state?.error ?? "").localizedCaseInsensitiveContains("dismissed")
    }

    private var hasDetail: Bool {
        if let output = state?.output, !output.isEmpty, !ToolTrace.looksLikeRawTrace(output) { return true }
        if part.tool == "question" { return false }
        if let input = state?.input, !input.isEmptyObject { return true }
        if let error = state?.error, !error.isEmpty, state?.status == "error", !isStopped { return true }
        return false
    }

    private var isExpanded: Bool {
        userExpanded ?? isRunning
    }

    private var toolName: String {
        Theme.toolName(part.tool)
    }

    private var toolTint: Color {
        isError && !isQuestionDismissed
            ? .red
            : (isStopped || isQuestionDismissed ? .secondary : Theme.toolTint(part.tool ?? ""))
    }

    private var headline: String {
        if part.tool == "question", let input = state?.input, let questions = toolQuestions(input), let first = questions.first {
            return first.question
        }
        if let title = state?.title, !title.isEmpty { return title }
        if let summary = state?.summary, !summary.isEmpty { return summary }
        if let error = state?.error, !error.isEmpty { return error }
        return toolName
    }

    /// Raw task traces currently surface in `state.output`; show the parsed
    /// task description as the single line instead of a repeated tool chip.
    private var rawTraceTitle: String? {
        guard let output = state?.output, ToolTrace.looksLikeRawTrace(output) else { return nil }
        let trace = ToolTrace.parse(output)
        return trace.description.isEmpty ? trace.prompt : trace.description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if hasDetail {
                    withAnimation(.easeInOut(duration: 0.15)) { userExpanded = !isExpanded }
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: Theme.toolSymbol(part.tool ?? ""))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(toolTint)
                        .frame(width: 28, height: 28)
                        .background(toolTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(toolName)
                                .font(.system(size: ChatTypography.micro(chatFontSize), weight: .semibold))
                                .foregroundStyle(toolTint)
                            Text(rawTraceTitle ?? headline)
                                .font(.system(size: ChatTypography.meta(chatFontSize), weight: .medium))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let rawTraceTitle, rawTraceTitle != toolName {
                                Text(toolName)
                                    .font(.system(size: ChatTypography.micro(chatFontSize), weight: .semibold))
                                    .foregroundStyle(toolTint)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(toolTint.opacity(0.10), in: Capsule())
                            }
                        }
                        if let summary = state?.summary, summary != headline, isExpanded {
                            Text(summary)
                                .font(.system(size: ChatTypography.meta(chatFontSize) - 1))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    if isStopped {
                        Text(NSLocalizedString("Stopped", comment: ""))
                            .font(.system(size: ChatTypography.micro(chatFontSize)))
                            .foregroundStyle(.secondary)
                    }
                    if let duration = state?.duration {
                        Text(duration)
                            .font(.system(size: ChatTypography.micro(chatFontSize), design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    if hasDetail {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if let input = state?.input, !input.isEmptyObject {
                    toolInputView(input)
                }
                if let output = state?.output, !output.isEmpty {
                    if ToolTrace.looksLikeRawTrace(output) {
                        TaskTraceCard(part: Part(type: "task", text: output), embedded: true)
                    } else {
                        MarkdownContentView(content: output)
                        sectionLabel(NSLocalizedString("Copy", comment: ""), content: output)
                    }
                }
            }

            if let error = state?.error, !error.isEmpty, isError, !isQuestionDismissed {
                detailSection(label: NSLocalizedString("Error", comment: ""), content: error, lineLimit: nil, copyable: true, tint: .red)
            } else if isQuestionDismissed, let error = state?.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: ChatTypography.micro(chatFontSize)))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isStopped ? Theme.subtleFill : Theme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isError && !isQuestionDismissed ? Color.red.opacity(0.45) : Theme.hairline)
        )
    }

    @ViewBuilder
    private func toolInputView(_ value: JSONValue) -> some View {
        let raw = value.displayText
        if ToolTrace.looksLikeRawTrace(raw) {
            TaskTraceCard(part: Part(type: "task", text: raw), embedded: true)
        } else if let questions = toolQuestions(value) {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel(NSLocalizedString("Input", comment: ""), content: prettyJSON(value) ?? raw)
                ForEach(questions) { question in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(question.header)
                            .font(.system(size: ChatTypography.micro(chatFontSize), weight: .semibold))
                            .foregroundStyle(toolTint)
                        Text(question.question)
                            .font(.system(size: ChatTypography.body(chatFontSize)))
                            .textSelection(.enabled)
                        if let details = question.details, !details.isEmpty {
                            Text(details)
                                .font(.system(size: ChatTypography.meta(chatFontSize)))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if !question.options.isEmpty {
                            Text(question.options.map(\.label).joined(separator: " · "))
                                .font(.system(size: ChatTypography.meta(chatFontSize)))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        } else if case .object(let object) = value {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel(NSLocalizedString("Input", comment: ""), content: prettyJSON(value) ?? raw)
                ForEach(object.keys.sorted(), id: \.self) { key in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(key)
                            .font(.system(size: ChatTypography.code(chatFontSize), weight: .semibold, design: .monospaced))
                            .foregroundStyle(key == "filePath" || key.hasSuffix("Path") ? Color.accentColor : .secondary)
                        Text(object[key]?.displayText ?? "")
                            .font(.system(size: ChatTypography.code(chatFontSize), design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            detailSection(
                label: NSLocalizedString("Input", comment: ""),
                content: raw,
                lineLimit: 6,
                copyable: true
            )
        }
    }

    private func sectionLabel(_ label: String, content: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: ChatTypography.micro(chatFontSize), weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content, forType: .string)
            } label: {
                Label(NSLocalizedString("Copy", comment: ""), systemImage: "doc.on.doc")
                    .font(.system(size: ChatTypography.micro(chatFontSize)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func detailSection(label: String, content: String, lineLimit: Int?, copyable: Bool, tint: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if copyable {
                sectionLabel(label, content: content)
            } else {
                Text(label)
                    .font(.system(size: ChatTypography.micro(chatFontSize), weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(content)
                .font(.system(
                    size: ChatTypography.code(chatFontSize),
                    design: .monospaced
                ))
                .lineSpacing(max(1, ChatTypography.lineSpacing(chatFontSize) * 0.35))
                .foregroundStyle(tint == .red ? .red : .primary)
                .textSelection(.enabled)
                .lineLimit(lineLimit)
        }
    }

    private func prettyJSON(_ value: JSONValue) -> String? {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: pretty, encoding: .utf8) else { return nil }
        return string
    }

    private func toolQuestions(_ value: JSONValue) -> [UserQuestionInfo]? {
        guard case .object(let object) = value,
              case .array(let raw) = object["questions"] ?? .null else { return nil }
        let decoder = JSONDecoder()
        return raw.compactMap { item in
            guard let data = try? JSONEncoder().encode(item) else { return nil }
            return try? decoder.decode(UserQuestionInfo.self, from: data)
        }
    }

}

/// Session-scoped error shown inside the conversation: a failure category
/// headline, the raw message, an actionable hint, and a Retry action.
private struct InlineErrorBubble: View {
    let error: SessionStore.InlineError
    var onRetry: () -> Void
    @State private var showsDetails = false

    /// Server errors arrive as "Name: message" followed by a JS stack trace.
    /// Keep the actionable first line; the trace stays behind a disclosure.
    private var summary: String {
        humanizedErrorSummary(error.message, kind: error.kind)
    }

    private var details: String? {
        let trimmed = error.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > summary.count else { return nil }
        return trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: error.kind.symbolName)
                    .foregroundStyle(.red)
                Text(error.kind.label)
                    .font(.caption.weight(.semibold))
            }
            Text(summary)
                .font(.caption)
                .textSelection(.enabled)
            Text(error.kind.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let details {
                DisclosureGroup(isExpanded: $showsDetails) {
                    ScrollView(.vertical) {
                        Text(details)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                } label: {
                    Text(NSLocalizedString("Show details", comment: ""))
                        .font(.caption)
                }
            }
            HStack(spacing: 8) {
                Button(NSLocalizedString("Retry", comment: "")) { onRetry() }
                    .controlSize(.small)
                if let details {
                    Button(NSLocalizedString("Copy details", comment: "")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(details, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bannerError)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Renders a unified diff with green/red/label line coloring.
func colorizedDiff(_ patch: String) -> AttributedString {
    var result = AttributedString()
    for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
        let text = String(line)
        var segment = AttributedString(text + "\n")
        if text.hasPrefix("@@") {
            segment.foregroundColor = .blue
        } else if text.hasPrefix("+") {
            segment.foregroundColor = .green
        } else if text.hasPrefix("-") {
            segment.foregroundColor = .red
        }
        result += segment
    }
    return result
}

/// Slash-command suggestions floating above the input; click completes the
/// draft (Enter still sends — send() routes "/name args" to the command API).
/// File search popup for @-mentions; paths are relative to the project root.
private struct FileMentionView: View {
    let results: [FsEntry]
    let query: String
    let selectedIndex: Int
    let onPick: (FsEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                Text(query.isEmpty
                     ? NSLocalizedString("Type to search files…", comment: "")
                     : NSLocalizedString("No matching files", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                    Button { onPick(entry) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.path)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(index == selectedIndex ? Color.accentColor.opacity(0.15) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().opacity(0.5)
                }
            }
        }
        .background(Theme.chromeFill)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(.horizontal, 12)
    }
}

private struct CommandPaletteView: View {
    let commands: [DevCommand]
    let selectedIndex: Int
    let onPick: (DevCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                Button { onPick(command) } label: {
                    HStack(spacing: 8) {
                        Text("/\(command.name)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        if let source = command.source {
                            Text(source)
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        Spacer(minLength: 8)
                        Text(command.description ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(index == selectedIndex ? Color.accentColor.opacity(0.15) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().opacity(0.5)
            }
        }
        .background(Theme.chromeFill)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .padding(.horizontal, 12)
    }
}

/// The agent asks the user something (question.asked). Supports single- and
/// multi-select options plus a free-text answer when `custom` is set.
private struct QuestionBanner: View {
    @EnvironmentObject var store: SessionStore
    let request: UserQuestionRequest

    private let contentMaxWidth: CGFloat = 760

    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0

    /// Selected labels per question index; single-select questions replace,
    /// multi-select questions toggle.
    @State private var selections: [Int: [String]] = [:]
    @State private var customAnswers: [Int: String] = [:]

    private var isComplete: Bool {
        request.questions.indices.allSatisfy { idx in
            let picked = selections[idx] ?? []
            if !picked.isEmpty { return true }
            return !(customAnswers[idx] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(request.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(NSLocalizedString("Question", comment: "") + " · " + question.header)
                            .font(.system(size: ChatTypography.body(chatFontSize), weight: .semibold))
                        Spacer()
                        if index == 0 {
                            Button(NSLocalizedString("Skip", comment: "")) {
                                Task { await store.rejectQuestion(request) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        }
                    }
                    Text(question.question)
                        .font(.system(size: ChatTypography.body(chatFontSize), weight: .medium))
                    if let details = question.details, !details.isEmpty {
                        Text(details)
                            .font(.system(size: ChatTypography.meta(chatFontSize)))
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 8) {
                        ForEach(question.options) { option in
                            optionRow(index: index, option: option, question: question)
                        }
                        if question.custom == true {
                            customField(index: index, question: question)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Image(systemName: isComplete ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.system(size: ChatTypography.meta(chatFontSize)))
                    .foregroundStyle(isComplete ? .green : .secondary)
                Text(isComplete
                     ? NSLocalizedString("Ready to send", comment: "")
                     : NSLocalizedString("Select an option to continue", comment: ""))
                    .font(.system(size: ChatTypography.meta(chatFontSize)))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(NSLocalizedString("Send Answers", comment: "")) {
                    let answers = request.questions.indices.map { idx -> [String] in
                        var picked = selections[idx] ?? []
                        let custom = customAnswers[idx]?.trimmingCharacters(in: .whitespaces) ?? ""
                        if !custom.isEmpty { picked.append(custom) }
                        return picked
                    }
                    Task { await store.answer(request, answers: answers) }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!isComplete)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.composerFill)
        .frame(maxWidth: contentMaxWidth)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
        }
    }

    private func isSelected(_ index: Int, _ label: String) -> Bool {
        (selections[index] ?? []).contains(label)
    }

    private func optionRow(index: Int, option: UserQuestionOption, question: UserQuestionInfo) -> some View {
        let selected = isSelected(index, option.label)
        return Button {
            let multiple = question.multiple ?? false
            var current = selections[index] ?? []
            if multiple {
                if current.contains(option.label) {
                    current.removeAll { $0 == option.label }
                } else {
                    current.append(option.label)
                }
                selections[index] = current
            } else {
                selections[index] = [option.label]
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: ChatTypography.meta(chatFontSize), weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: ChatTypography.body(chatFontSize), weight: selected ? .semibold : .regular))
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: ChatTypography.meta(chatFontSize)))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Theme.cardFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.55) : Theme.hairline, lineWidth: selected ? 2 : 1)
            }
            .shadow(color: selected ? Color.accentColor.opacity(0.18) : .clear, radius: 6, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func customField(index: Int, question: UserQuestionInfo) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isSelected(index, customAnswers[index] ?? "") ? "checkmark.circle.fill" : "pencil")
                .foregroundStyle(.secondary)
            TextField("Custom answer…", text: Binding(
                get: { customAnswers[index] ?? "" },
                set: { customAnswers[index] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }
}
