import SwiftUI
import AppKit

private struct ModelGroup: Identifiable {
    let provider: String
    let choices: [ModelChoice]

    var id: String { provider }
}

struct ChatView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var providers: ProviderStore
    @EnvironmentObject var server: ServerManager

    /// Keep the conversation readable on wide displays; Codex-style centered column.
    private let contentMaxWidth: CGFloat = 760

    @AppStorage(AppSettings.Keys.autoScroll)
    private var autoScroll = true
    @AppStorage(AppSettings.Keys.sendOnEnter)
    private var sendOnEnter = true
    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0

    @State private var showDiff = false
    /// False once the user scrolls away from the tail; pauses stream follow
    /// and reveals the "Back to latest" pill.
    @State private var isNearBottom = true

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
    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var searchMatchIndex = 0
    @State private var searchJumpTick = 0
    @State private var dragHover = false
    @State private var showModelPicker = false
    @State private var modelQuery = ""

    private func applyCompletion(_ command: DevCommand) {
        store.draft = "/" + command.name + " "
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

    private func historyUp() {
        let history = AppSettings.promptHistory
        guard !history.isEmpty else { return }
        if historyIndex == nil {
            draftBeforeHistory = store.draft
            historyIndex = 0
        } else if historyIndex! + 1 < history.count {
            historyIndex! += 1
        }
        store.draft = history[history.count - 1 - historyIndex!]
    }

    private func historyDown() {
        guard let index = historyIndex else { return }
        let history = AppSettings.promptHistory
        if index == 0 {
            historyIndex = nil
            store.draft = draftBeforeHistory
        } else {
            historyIndex! -= 1
            store.draft = history[history.count - 1 - historyIndex!]
        }
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
            if store.selectedSessionID == nil {
                emptyState
            } else {
                sessionArea
            }
        }
        .background(Theme.canvas)
        .sheet(isPresented: $showDiff) {
            DiffSheet()
        }
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
                Text("Select a session or create a new one")
                    .foregroundStyle(.secondary)
                if server.state == .running {
                    Button {
                        store.createSession()
                    } label: {
                        Label("New Session", systemImage: "plus.circle.fill")
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
                        Button("Start Server") { server.start() }
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

    private func useStarterPrompt(_ prompt: String) {
        store.draft = prompt
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
                    Text("Start a conversation")
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

    /// "ctx 12.3k/200k · $0.50" — context usage (last assistant input tokens,
    /// vs the selected model's limit) plus session cost, in the header.
    /// Context usage of the selected session: the last assistant response's
    /// input tokens approximate what the next call will feed the model.
    private var contextUsage: (used: Double, limit: Double?)? {
        let effectiveModel = store.selectedModel
            ?? (store.serverDefaultModel.isEmpty ? nil : store.serverDefaultModel)
        let limit = providers.contextLimit(for: effectiveModel)
        let used = store.messages
            .last(where: { $0.info.role == "assistant" })?
            .info.tokens?.input ?? 0
        guard limit != nil || used > 0 else { return nil }
        return (used, limit)
    }

    private func sessionUsage(_ session: Session) -> String? {
        var pieces: [String] = []
        if let usage = contextUsage {
            var context = compactCount(usage.used)
            if let limit = usage.limit, limit > 0 {
                context += "/\(compactCount(limit))"
                pieces.append("ctx \(context) · \(Int((min(usage.used / limit, 1) * 100).rounded()))%")
            } else {
                pieces.append("ctx \(context)")
            }
        }
        if let cost = session.cost, cost > 0 {
            pieces.append("$\(String(format: cost < 0.01 ? "%.4f" : "%.2f", cost))")
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " · ")
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

    /// Current match excerpt with the query highlighted, shown in the search bar.
    private var searchSnippet: AttributedString? {
        guard !searchQuery.isEmpty, searchMatchIndex < visibleMessages.count else { return nil }
        let message = visibleMessages[searchMatchIndex]
        let text = message.parts.compactMap { $0.text }.joined(separator: " · ")
        guard let range = text.range(of: searchQuery, options: .caseInsensitive) else { return nil }
        let lower = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
        var attributed = AttributedString(String(text[lower..<upper]))
        if let hit = attributed.range(of: searchQuery, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[hit].backgroundColor = Color.yellow.opacity(0.45)
        }
        return attributed
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
        switch variant.lowercased() {
        case "none": return NSLocalizedString("None", comment: "effort level")
        case "low": return NSLocalizedString("Low", comment: "effort level")
        case "medium": return NSLocalizedString("Medium", comment: "effort level")
        case "high": return NSLocalizedString("High", comment: "effort level")
        case "xhigh": return NSLocalizedString("Extra high", comment: "effort level")
        case "max": return NSLocalizedString("Max", comment: "effort level")
        default: return variant.prefix(1).uppercased() + variant.dropFirst()
        }
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

    private func adjustChatFont(by delta: Double) {
        chatFontSize = min(
            ChatTypography.maxFontSize,
            max(ChatTypography.minFontSize, chatFontSize + delta)
        )
    }

    private func headerButton(
        _ systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var chatFontMenu: some View {
        Menu {
            Button {
                adjustChatFont(by: -1)
            } label: {
                Label(NSLocalizedString("Smaller text", comment: ""), systemImage: "textformat.size.smaller")
            }
            .disabled(chatFontSize <= ChatTypography.minFontSize)

            Button {
                adjustChatFont(by: 1)
            } label: {
                Label(NSLocalizedString("Larger text", comment: ""), systemImage: "textformat.size.larger")
            }
            .disabled(chatFontSize >= ChatTypography.maxFontSize)

            Divider()
            ForEach([13, 14, 15, 16, 17, 18, 20, 22, 24, 26, 28, 30], id: \.self) { size in
                Button {
                    chatFontSize = Double(size)
                } label: {
                    if Int(chatFontSize) == size {
                        Label("\(size) pt", systemImage: "checkmark")
                    } else {
                        Text("\(size) pt")
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("Aa")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(Int(chatFontSize))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(NSLocalizedString("Chat text size", comment: ""))
    }

    /// Composer model picker: a popover with type-to-filter (64+ models make
    /// a nested menu painful) and a "recent" section fed by explicit picks.
    private var composerModelMenu: some View {
        Button {
            modelQuery = ""
            showModelPicker = true
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(selectedModelProvider.map(providerColor) ?? Color.secondary)
                    .frame(width: 6, height: 6)
                Text(selectedModelLabel)
                    .lineLimit(1)
                if let provider = selectedModelProvider, !selectedModelLabel.contains("·") {
                    Text(provider)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: ChatTypography.meta(chatFontSize) + 0.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .fixedSize()
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
        AppSettings.recentModels.compactMap { id in
            providers.allModelChoices.first { $0.id == id }
        }
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
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text(selectedEffortLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: ChatTypography.meta(chatFontSize)))
            .foregroundStyle(.tertiary)
            .padding(.vertical, 3)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(NSLocalizedString("Reasoning effort for this model", comment: ""))
    }

    private var composerSendButton: some View {
        Button {
            if store.isSending {
                store.abort()
            } else {
                store.send()
            }
            focusTrigger += 1
        } label: {
            Image(systemName: store.isSending ? "stop.fill" : "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(
                    store.isSending || canSend
                        ? Color(nsColor: .textBackgroundColor)
                        : Color.secondary.opacity(0.75)
                )
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(
                        store.isSending
                            ? Color.red.opacity(0.85)
                            : (canSend ? Color.primary : Color.secondary.opacity(0.12))
                    )
                )
                .overlay(
                    Circle().stroke(
                        store.isSending || canSend ? Color.clear : Theme.softStroke,
                        lineWidth: 1
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
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
        .padding(.bottom, 14)
        .help(NSLocalizedString("Back to latest", comment: ""))
    }

    private var sessionArea: some View {
        VStack(spacing: 0) {
            if let session = store.selectedSession {
                HStack(spacing: 7) {
                    if let usage = sessionUsage(session) {
                        Text(usage)
                            .font(.system(size: ChatTypography.micro(chatFontSize)))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    chatFontMenu
                    headerButton(
                        "magnifyingglass",
                        help: NSLocalizedString("Search in conversation (⌘F)", comment: "")
                    ) {
                        showSearch.toggle()
                        if !showSearch { searchQuery = "" }
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    headerButton(
                        "rectangle.split.2x1",
                        help: NSLocalizedString("Review file changes", comment: "")
                    ) {
                        showDiff = true
                    }
                    headerButton(
                        "arrow.down.right.and.arrow.up.left",
                        help: store.isCompacting
                            ? NSLocalizedString("Compacting…", comment: "")
                            : NSLocalizedString("Compact conversation", comment: "")
                    ) {
                        Task { await store.compact() }
                    }
                    .disabled(store.isCompacting || store.isSending)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
                .frame(height: 34)
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: 1)
                }
            }

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
                    Text("Session is reverted to an earlier message; new prompts continue from there.")
                        .font(.caption)
                    Spacer()
                    Button("Unrevert") {
                        Task { await store.unrevert() }
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.bannerWarning)
                Divider()
            }

                if showSearch {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Search in conversation", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .onSubmit {
                            // Enter = next match, Shift+Enter = previous.
                            let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                            jumpSearch(backwards ? -1 : 1)
                        }
                    if searchMatchIndex < visibleMessages.count, let snippet = searchSnippet {
                        Text("\(searchMatchIndex + 1)/\(visibleMessages.count)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(snippet)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if !searchQuery.isEmpty {
                        Text("\(visibleMessages.count) matches")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        showSearch = false
                        searchQuery = ""
                        searchMatchIndex = 0
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.chromeFill)
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
                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if store.isLoadingMessages && store.messages.isEmpty && searchQuery.isEmpty {
                            VStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading conversation…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 80)
                        } else if store.messages.isEmpty && searchQuery.isEmpty {
                            newConversationState
                        } else {
                            LazyVStack(alignment: .leading, spacing: 26) {
                                ForEach(visibleMessages) { message in
                                    MessageBubble(message: message, searchQuery: searchQuery)
                                        .id(message.id)
                                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                                }
                                if searchQuery.isEmpty, let error = store.inlineError, error.sessionID == store.selectedSessionID {
                                    InlineErrorBubble(error: error) {
                                        store.retryLastPrompt()
                                    }
                                    .id("inline-error")
                                }
                                if !searchQuery.isEmpty && visibleMessages.isEmpty {
                                    Text("No messages match “\(searchQuery)”")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .animation(.easeOut(duration: 0.18), value: store.messages.count)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 26)
                    .frame(maxWidth: contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .background(ScrollTracker { near in
                        isNearBottom = near
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
                    guard isNearBottom, autoScroll, searchQuery.isEmpty, let last = store.messages.last?.id else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
                .onChange(of: store.messages.count) { _ in
                    guard isNearBottom, autoScroll, searchQuery.isEmpty, let last = store.messages.last?.id else { return }
                    proxy.scrollTo(last, anchor: .bottom)
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
                .onChange(of: searchJumpTick) { _ in
                    guard searchMatchIndex < visibleMessages.count else { return }
                    proxy.scrollTo(visibleMessages[searchMatchIndex].id, anchor: .center)
                }
            }

            if !store.queuedPrompts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.queuedPrompts) { queued in
                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text(queued.text)
                                .font(.system(size: 14))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !queued.attachments.isEmpty {
                                Label("\(queued.attachments.count)", systemImage: "paperclip")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .help(NSLocalizedString("Queued attachments", comment: ""))
                            }
                            Spacer(minLength: 8)
                            Button {
                                store.editQueued(queued)
                                focusTrigger += 1
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(NSLocalizedString("Edit queued prompt", comment: ""))
                            Button {
                                Task { await store.sendQueuedNow(queued) }
                            } label: {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(NSLocalizedString("Send now — stops the current generation", comment: ""))
                            Button {
                                store.removeQueued(queued)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(NSLocalizedString("Remove queued prompt", comment: ""))
                        }
                        // Drag one queued chip onto another to reorder.
                        .draggable(queued.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            guard let dragged = items.first,
                                  let id = UUID(uuidString: dragged),
                                  id != queued.id,
                                  store.queuedPrompts.contains(where: { $0.id == id }) else { return false }
                            store.moveQueued(id, before: queued.id)
                            return true
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Theme.subtleFill)
            }

            Divider()

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
                if let request = store.pendingPermissions.first(where: { $0.sessionID == store.selectedSessionID }) {
                    PermissionBanner(request: request, pendingCount: store.pendingPermissions.count)
                }
                if let request = store.pendingQuestions.first(where: { $0.sessionID == store.selectedSessionID }) {
                    QuestionBanner(request: request)
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
                                        Text(attachment.filename ?? (attachment.mime.hasPrefix("image/") ? "image" : "file"))
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
                              placeholder: NSLocalizedString("Write a message…", comment: ""),
                              onHistoryUp: historyUp, onHistoryDown: historyDown,
                              onArrowUp: handlePaletteUp, onArrowDown: handlePaletteDown,
                              onTab: handlePaletteTab,
                              onReturn: handlePaletteReturn,
                              onPasteImage: { data in store.addImageAttachment(data: data) },
                              onPasteFileURLs: { urls in addPastedFiles(urls) },
                              onDragHover: { dragHover = $0 },
                              onEscape: handleEscape,
                              onContentHeight: { inputHeight = $0 }) { store.send() }
                        .frame(height: inputHeight)
                        .padding(.horizontal, 12)
                        .padding(.top, 9)

                    HStack(spacing: 8) {
                        if store.isSending {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Generating…")
                                .font(.system(size: ChatTypography.meta(chatFontSize), weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        if let usage = contextUsage {
                            ContextMeter(used: usage.used, limit: usage.limit)
                        }
                        Spacer(minLength: 8)
                        composerModelMenu
                        if !effortVariants.isEmpty {
                            composerEffortMenu
                        }
                        composerSendButton
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 9)
                }
                .background(Theme.composerFill)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
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
        .onChange(of: store.draft) { _ in
            paletteIndex = 0
            mentionIndex = 0
            updateMentionResults()
        }
        .onChange(of: store.selectedSessionID) { _ in
            isNearBottom = true
            focusTrigger += 1
        }
        .sheet(isPresented: $showDiff) {
            DiffSheet()
        }
    }
}

/// Tracks whether the conversation sits near the bottom of the scroll view.
/// SwiftUI's ScrollView is NSScrollView-backed on macOS, so the tracker sits
/// as a background of the scrolled content and observes the enclosing clip
/// view's bounds changes directly — reliable even with a lazy stack whose
/// tail views are virtualized away.
private struct ScrollTracker: NSViewRepresentable {
    var onNearBottom: (Bool) -> Void

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
        var onNearBottom: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private static let threshold: CGFloat = 80

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
            onNearBottom(distance <= Self.threshold || document.bounds.height <= clip.height)
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
                Text("Working…")
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

/// File changes made during the selected session, with unified diffs.
struct DiffSheet: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var filterQuery = ""
    @State private var expandedFiles: Set<String> = []
    @State private var allExpanded = false

    private var filteredDiffs: [FileDiff] {
        let query = filterQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.diffs }
        return store.diffs.filter { $0.file.localizedCaseInsensitiveContains(query) }
    }

    private var totalAdditions: Int { store.diffs.reduce(0) { $0 + Int($1.additions ?? 0) } }
    private var totalDeletions: Int { store.diffs.reduce(0) { $0 + Int($1.deletions ?? 0) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Changes")
                    .font(.headline)
                Text("Files: \(store.diffs.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("+\(totalAdditions)")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("-\(totalDeletions)")
                    .font(.caption)
                    .foregroundStyle(.red)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("Filter files", text: $filterQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                }
                Button(allExpanded ? "Collapse All" : "Expand All") {
                    withAnimation(.easeInOut(duration: 0.15)) { setAllExpanded(!allExpanded) }
                }
                .controlSize(.small)
                .disabled(store.diffs.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)

            Divider()

            if store.isLoadingDiff {
                VStack {
                    ProgressView().controlSize(.regular)
                    Text("Loading diff…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.diffs.isEmpty {
                VStack {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No file changes in this session.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredDiffs.isEmpty {
                VStack {
                    Text("No files match the filter.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredDiffs) { diff in
                            DiffFileRow(
                                diff: diff,
                                isExpanded: allExpanded || expandedFiles.contains(diff.id)
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) { toggle(diff.id) }
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 680, height: 520)
        .onAppear {
            Task { await store.loadDiff() }
        }
    }

    private func setAllExpanded(_ value: Bool) {
        allExpanded = value
        expandedFiles = value ? Set(store.diffs.map(\.id)) : []
    }

    private func toggle(_ id: String) {
        let isCurrentlyExpanded = allExpanded || expandedFiles.contains(id)
        if isCurrentlyExpanded {
            if allExpanded {
                expandedFiles = Set(store.diffs.map(\.id))
                expandedFiles.remove(id)
                allExpanded = false
            } else {
                expandedFiles.remove(id)
            }
        } else {
            expandedFiles.insert(id)
        }
    }
}

private struct DiffFileRow: View {
    let diff: FileDiff
    let isExpanded: Bool
    var onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { onToggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                        .font(.caption.weight(.bold))
                    Text((diff.file as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("+\(Int(diff.additions ?? 0))")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text("-\(Int(diff.deletions ?? 0))")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(10)
            .help(diff.file)

            if isExpanded, let patch = diff.patch, !patch.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(colorizedDiff(patch))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(10)
                }
                .frame(maxHeight: 320)
            }
        }
        .background(Theme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.softStroke)
        )
    }

    private var statusIcon: String {
        switch diff.status {
        case "added": return "A"
        case "deleted": return "D"
        default: return "M"
        }
    }

    private var statusColor: Color {
        switch diff.status {
        case "added": return .green
        case "deleted": return .red
        default: return .orange
        }
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
        /// Last value forwarded to the binding. When `textView.string` equals
        /// this, a differing binding is an external edit — otherwise it is a
        /// stale SwiftUI render and must not be written back (it would undo
        /// fast typing/deletion between renders).
        var lastSyncedText: String?
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            lastSyncedText = textView.string
            onTextChange?(textView.string)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let textView = ChatTextView.make(
            frame: NSRect(x: 0, y: 0, width: 480, height: 44)
        )
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
        textView.minSize = NSSize(width: 0, height: 44)
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
            // Never touch marked text (IME composition in flight) and never
            // echo our own binding updates back into the view.
            if !textView.hasMarkedText() && textView.string != coordinator.lastSyncedText {
                textView.string = text
                coordinator.lastSyncedText = text
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
        fatalError("init(coder:) is not supported")
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
        let hasShift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
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
        guard let onContentHeight, let layoutManager else { return }
        let used = layoutManager.usedRect(for: textContainer!).height
        let total = used + textContainerInset.height * 2 + 6
        let height = max(44, min(160, ceil(total)))
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
        (placeholder as NSString).draw(
            at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height - 3),
            withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
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
        let hasOption = event.modifierFlags.contains(.option)
        if hasOption && event.keyCode == 126 { // Option+↑
            onHistoryUp?()
            return
        }
        if hasOption && event.keyCode == 125 { // Option+↓
            onHistoryDown?()
            return
        }
        if event.keyCode == 126, let up = onArrowUp, up() { return } // ↑
        if event.keyCode == 125, let down = onArrowDown, down() { return } // ↓
        if event.keyCode == 48, let tab = onTab, tab() { return } // Tab
        if event.keyCode == 53, let onEscape { onEscape(); return } // Escape
        super.keyDown(with: event)
    }
}

private struct MessageBubble: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var providers: ProviderStore
    let message: MessageRecord
    var searchQuery: String = ""

    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0

    @State private var hovered = false
    @State private var copied = false

    private var isStreamingThis: Bool {
        store.isSending && store.messages.last?.id == message.id
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

    var body: some View {
        Group {
            if isUser {
                userMessage
            } else {
                assistantMessage
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .animation(.easeInOut(duration: 0.12), value: hovered)
        .onHover { hovered = $0 }
        .contextMenu {
            if isUser {
                Button("Edit & resend…") {
                    Task { await store.editMessage(message) }
                }
                Button("Revert to here…") {
                    Task { await store.revert(to: message) }
                }
                .disabled(isStreamingThis)
            } else {
                Button("Revert to here…") {
                    Task { await store.revert(to: message) }
                }
                .disabled(isStreamingThis)
            }
        }
    }

    private var userMessage: some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 80)
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
            .padding(.vertical, 10)
            .background(
                Theme.userBubble,
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Theme.userBubbleStroke)
            )
            .overlay(alignment: .topTrailing) {
                if hovered && !isStreamingThis {
                    hoverActionBar
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                }
            }
        }
    }

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let elapsed = message.info.elapsedDuration {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: microSize, weight: .medium))
                    Text(String(format: NSLocalizedString("Took %@", comment: "assistant response duration"), elapsed))
                        .font(.system(size: microSize, weight: .medium))
                }
                .foregroundStyle(.tertiary)
                .padding(.bottom, 1)
            }

            ForEach(message.parts) { part in
                PartView(
                    part: part,
                    useMarkdown: true,
                    isStreaming: isStreamingThis,
                    searchQuery: searchQuery
                )
            }

            if let metadata = assistantMetadata {
                Text(metadata)
                    .font(.system(size: microSize))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .padding(.top, 1)
            }
        }
        .font(.system(size: ChatTypography.body(chatFontSize)))
        .lineSpacing(ChatTypography.lineSpacing(chatFontSize))
        .padding(.vertical, 3)
        .overlay(alignment: .topTrailing) {
            if hovered && !isStreamingThis {
                hoverActionBar
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }
        }
    }

    /// Hover action strip: copy, edit & resend (user messages), revert.
    private var hoverActionBar: some View {
        HStack(spacing: 2) {
            actionButton(
                copied ? "checkmark" : "doc.on.doc",
                help: NSLocalizedString("Copy message", comment: ""),
                tint: copied ? Color.green : Color.secondary
            ) {
                copyMessage()
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.softStroke))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        .padding(6)
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
        guard !messageText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(messageText, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copied = false
        }
    }

    /// Compact usage line under an assistant turn. Duration is shown above
    /// the response, matching Codex's reading flow.
    private var assistantMetadata: String? {
        let info = message.info
        var pieces: [String] = []
        if let model = info.modelID {
            let identifier = [info.providerID, info.modelID].compactMap { $0 }.joined(separator: "/")
            if let name = providers.modelDisplayName(for: identifier, fuzzyModel: model) {
                pieces.append(prettyModelName(name))
            }
        }
        if let variant = info.variant {
            pieces.append(String(format: NSLocalizedString("Effort: %@", comment: ""), variant))
        }
        if let tokens = info.tokens {
            // Harness semantics: input = uncached input of this request,
            // cache.read = context served from cache, output/reasoning =
            // tokens generated for this reply. "total" spans the whole
            // processed context and is intentionally not shown here.
            let generated = (tokens.output ?? 0) + (tokens.reasoning ?? 0)
            if generated > 0 {
                pieces.append(String(format: NSLocalizedString("Output %@", comment: "per-message tokens"), compactCount(generated)))
            }
            if let input = tokens.input, input > 0 {
                pieces.append(String(format: NSLocalizedString("Input %@", comment: "per-message uncached tokens"), compactCount(input)))
            }
            if let cached = tokens.cache?.read, cached > 0 {
                pieces.append(String(format: NSLocalizedString("Cached %@", comment: "per-message cache hits"), compactCount(cached)))
            }
        }
        if let cost = info.cost, cost > 0 {
            pieces.append("$\(String(format: cost < 0.01 ? "%.4f" : "%.2f", cost))")
        }
        guard !pieces.isEmpty else { return nil }
        return pieces.joined(separator: " · ")
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
                Text("Todos")
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

/// Progressive reveal for streaming assistant text. Deltas land in ~120ms
/// batches; this drains the backlog at ~40ms ticks so text appears like
/// continuous typing instead of whole blocks. The step scales with the backlog
/// (bigger burst → faster typing) so the view never falls far behind.
private struct StreamingTextView: View {
    let target: String
    let useMarkdown: Bool
    let searchQuery: String

    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0

    @State private var revealedCount = 0
    @State private var lastTarget = ""

    private var content: String {
        let revealed = revealedCount >= target.count
            ? target
            : String(target.prefix(revealedCount))
        return revealed + " ▍"
    }

    var body: some View {
        Group {
            // Mid-stream: plain text keeps 40ms typewriter updates cheap;
            // markdown re-parsing per frame is wasted work, so formatting
            // lands once the run finishes.
            if useMarkdown && revealedCount >= target.count {
                MarkdownContentView(content: content, searchQuery: searchQuery)
            } else {
                Text(content)
                    .font(.system(size: ChatTypography.body(chatFontSize)))
                    .lineSpacing(ChatTypography.lineSpacing(chatFontSize))
                    .textSelection(.enabled)
            }
        }
        .onReceive(Timer.publish(every: 0.04, on: .main, in: .common).autoconnect()) { _ in
            let backlog = target.count - revealedCount
            guard backlog > 0 else { return }
            revealedCount += min(max(2, backlog / 10), 160)
        }
        .onChange(of: target) { newValue in
            // Appends keep the reveal position; a replaced body (snapshot
            // refresh) snaps to the new content.
            if !newValue.hasPrefix(String(lastTarget.prefix(revealedCount))) {
                revealedCount = newValue.count
            }
            lastTarget = newValue
        }
        .onAppear { lastTarget = target }
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
            if isStreaming {
                StreamingTextView(
                    target: part.text ?? "",
                    useMarkdown: useMarkdown,
                    searchQuery: searchQuery
                )
            } else {
                let content = part.text ?? ""
                if useMarkdown {
                    MarkdownContentView(content: content, searchQuery: searchQuery)
                } else if !searchQuery.isEmpty, let attributed = highlightedAttributedString(content, query: searchQuery) {
                    Text(attributed)
                        .font(.system(size: ChatTypography.body(chatFontSize)))
                        .lineSpacing(ChatTypography.lineSpacing(chatFontSize))
                        .textSelection(.enabled)
                } else {
                    Text(content)
                        .font(.system(size: ChatTypography.body(chatFontSize)))
                        .lineSpacing(ChatTypography.lineSpacing(chatFontSize))
                        .textSelection(.enabled)
                }
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
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: ChatTypography.meta(chatFontSize) - 1))
                    Text("Thinking")
                        .font(.system(size: ChatTypography.meta(chatFontSize), weight: .medium))
                }
                .foregroundStyle(.secondary)
            }
        case "tool":
            ToolCardView(part: part)
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

fileprivate func compactCount(_ value: Double) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
    return String(Int(value))
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
    case divider
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
        guard let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) else { return nil }
        MarkdownCache.inline.setObject(CachedBox(attributed), forKey: key)
        return attributed
    }
}

private struct CodeBlockView: View {
    let lang: String
    let code: String

    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0

    @State private var copied = false

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
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}

/// Claude-desktop-style context meter: slim progress bar + numeric readout,
/// escalating to orange/red as the conversation fills the context window.
private struct ContextMeter: View {
    let used: Double
    let limit: Double?

    private var ratio: Double? {
        guard let limit, limit > 0 else { return nil }
        return min(max(used / limit, 0), 1)
    }

    private var tint: Color {
        guard let ratio else { return .secondary }
        return ratio > 0.85 ? .red : (ratio > 0.6 ? .orange : .secondary)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let limit, limit > 0, let ratio {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 76, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(tint)
                            .frame(width: max(3, 76 * ratio))
                    }
                Text("\(compactCount(used)) / \(compactCount(limit)) · \(Int((ratio * 100).rounded()))%")
                    .foregroundStyle(tint)
                    .monospacedDigit()
            } else {
                Text("\(compactCount(used)) tokens")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .help(NSLocalizedString(
            "Context window usage — input tokens of the last response vs the model's context limit",
            comment: ""
        ))
    }
}

/// Decoded image cache — bubbles re-render on every stream flush, and
/// re-decoding a multi-MB screenshot each time would spike the CPU.
private enum ImageCache {
    static let cache = NSCache<NSString, NSImage>()
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
            .help("Open attachment")
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
        .help("Open attachment")
    }

    private func loadImage() -> NSImage? {
        guard let urlString else { return nil }
        let key = urlString as NSString
        if let cached = ImageCache.cache.object(forKey: key) {
            return cached
        }
        let image: NSImage?
        if urlString.hasPrefix("data:"), let url = URL(string: urlString), let data = try? Data(contentsOf: url) {
            image = NSImage(data: data)
        } else if let url = URL(string: urlString), url.isFileURL {
            image = NSImage(contentsOf: url)
        } else {
            image = nil
        }
        if let image {
            ImageCache.cache.setObject(image, forKey: key)
        }
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
                Text("Product agreement confirmation required")
                    .font(.headline)
            }
            Text("Before any model can be called, deveco requires you to accept its product terms and privacy statement.")
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
                        Text("I have read and accept")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isAccepting)
                Text("Equivalent to `deveco auth consent --accept`.")
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
private struct ToolCardView: View {
    let part: Part
    @AppStorage(AppSettings.Keys.chatFontSize)
    private var chatFontSize = 15.0

    /// nil = follow the default policy (running tools expand, finished ones
    /// collapse); after the user toggles, their choice wins.
    @State private var userExpanded: Bool?

    private var state: ToolState? { part.state }

    private var isRunning: Bool { state?.status == "running" }
    private var isError: Bool { state?.status == "error" }

    private var hasDetail: Bool {
        if let output = state?.output, !output.isEmpty { return true }
        if part.tool == "question" { return false }
        if state?.input != nil { return true }
        if let error = state?.error, !error.isEmpty, isError { return true }
        return false
    }

    private var isExpanded: Bool {
        userExpanded ?? (isRunning && hasDetail)
    }

    private var toolName: String {
        Theme.toolName(part.tool)
    }

    private var toolTint: Color {
        isError ? .red : Theme.toolTint(part.tool ?? "")
    }

    private var headline: String {
        if part.tool == "question", let input = state?.input, let questions = toolQuestions(input), let first = questions.first {
            return first.question
        }
        if let title = state?.title, !title.isEmpty { return title }
        if let summary = state?.summary, !summary.isEmpty { return summary }
        return toolName
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
                        .frame(width: 26, height: 26)
                        .background(toolTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(toolName)
                                .font(.system(size: ChatTypography.micro(chatFontSize), weight: .semibold))
                                .foregroundStyle(toolTint)
                            Text(headline)
                                .font(.system(size: ChatTypography.meta(chatFontSize), weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
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
                    detailSection(
                        label: NSLocalizedString("Input", comment: ""),
                        content: inputSummary(input),
                        lineLimit: 6,
                        copyable: true
                    )
                }
                if let output = state?.output, !output.isEmpty {
                    detailSection(label: NSLocalizedString("Output", comment: ""), content: output, lineLimit: nil, copyable: true)
                }
            }

            if let error = state?.error, !error.isEmpty, isError {
                detailSection(label: NSLocalizedString("Error", comment: ""), content: error, lineLimit: nil, copyable: true, tint: .red)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isError ? Color.red.opacity(0.45) : Theme.hairline)
        )
    }

    private func detailSection(label: String, content: String, lineLimit: Int?, copyable: Bool, tint: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: ChatTypography.micro(chatFontSize), weight: .semibold))
                    .foregroundStyle(tint)
                Spacer()
                if copyable {
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

    /// Compact, human-readable tool input: strings shown raw, nested
    /// structures inlined as "key: value" pairs (no pretty-printed JSON).
    private func inputSummary(_ value: JSONValue) -> String {
        if let questions = toolQuestions(value) {
            return questions.map { question in
                let options = question.options.map(\.label).joined(separator: " / ")
                let detail = question.details ?? ""
                return "\(question.header)：\(question.question)\n选项：\(options)\(detail.isEmpty ? "" : "\n\(detail)")"
            }
            .joined(separator: "\n\n")
        }
        guard case .object(let object) = value else { return value.displayText }
        return object
            .sorted { $0.key < $1.key }
            .map { key, item in
                if case .string(let text) = item { return "\(key): \(text)" }
                if case .array(let items) = item, items.count <= 6 {
                    return "\(key): \(items.map(\.displayText).joined(separator: ", "))"
                }
                return "\(key): \(item.displayText)"
            }
            .joined(separator: "\n")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: error.kind.symbolName)
                    .foregroundStyle(.red)
                Text(error.kind.label)
                    .font(.caption.weight(.semibold))
            }
            Text(error.message)
                .font(.caption)
                .textSelection(.enabled)
            Text(error.kind.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Retry") { onRetry() }
                .controlSize(.small)
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

private struct PermissionBanner: View {
    @EnvironmentObject var store: SessionStore
    let request: PermissionRequest
    var pendingCount: Int = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("需要授权")
                        .font(.title3.weight(.semibold))
                    Text(request.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if pendingCount > 1 {
                    Text("(\(pendingCount) pending)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if !request.detail.isEmpty {
                Text(request.detail)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }
            HStack(spacing: 12) {
                Button("Allow once") {
                    store.reply(to: request, reply: "once")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Always allow") {
                    store.reply(to: request, reply: "always")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Button("Reject", role: .destructive) {
                    store.reply(to: request, reply: "reject")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.bannerWarning)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.orange.opacity(0.35), lineWidth: 1)
        )
    }
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
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(request.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(question.header)
                            .font(.headline)
                        Spacer()
                        if index == 0 {
                            Button("Skip") {
                                Task { await store.rejectQuestion(request) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        }
                    }
                    Text(question.question)
                        .font(.title3.weight(.medium))
                    if let details = question.details, !details.isEmpty {
                        Text(details)
                            .font(.callout)
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
                    .foregroundStyle(isComplete ? .green : .secondary)
                Text(isComplete
                     ? NSLocalizedString("Ready to send", comment: "")
                     : NSLocalizedString("Select an option to continue", comment: ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Send Answers") {
                    let answers = request.questions.indices.map { idx -> [String] in
                        var picked = selections[idx] ?? []
                        let custom = customAnswers[idx]?.trimmingCharacters(in: .whitespaces) ?? ""
                        if !custom.isEmpty { picked.append(custom) }
                        return picked
                    }
                    Task { await store.answer(request, answers: answers) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!isComplete)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .padding(16)
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
                    .font(.body.weight(.medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.body.weight(selected ? .semibold : .regular))
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.callout)
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
