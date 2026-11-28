import SwiftUI
import AppKit

enum WorkPanelTab: String, CaseIterable, Identifiable {
    case review
    case context
    case files
    case vcs
    case children

    var id: String { rawValue }

    var label: String {
        switch self {
        case .review: return NSLocalizedString("Review", comment: "")
        case .context: return NSLocalizedString("Context", comment: "")
        case .files: return NSLocalizedString("Files", comment: "")
        case .vcs: return NSLocalizedString("VCS", comment: "")
        case .children: return NSLocalizedString("Children", comment: "")
        }
    }

    var symbol: String {
        switch self {
        case .review: return "doc.text.magnifyingglass"
        case .context: return "gauge.with.dots.needle.33percent"
        case .files: return "folder"
        case .vcs: return "source.control"
        case .children: return "square.on.square"
        }
    }
}

/// Docked work panel for session artifacts. It stays closed unless the user
/// opens it explicitly, and each session keeps its own tab/selection state in
/// SessionStore so switching chats never leaks panel context.
struct WorkPanelView: View {
    @EnvironmentObject var store: SessionStore
    @Binding var isOpen: Bool

    private var sessionID: String? { store.selectedSessionID }
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var showsTabLabels: Bool {
        horizontalSizeClass != .compact
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(WorkPanelTab.allCases) { tab in
                    Button {
                        if let sessionID {
                            store.setWorkPanelTab(tab)
                            store.workPanelOpenBySession[sessionID] = true
                        }
                        isOpen = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 11))
                            if showsTabLabels {
                                Text(tab.label)
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .padding(.horizontal, showsTabLabels ? 8 : 6)
                        .padding(.vertical, 5)
                        .background(
                            isOpen && store.workPanelTab == tab
                                ? Theme.chipFill
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .foregroundStyle(
                            isOpen && store.workPanelTab == tab ? .primary : .secondary
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tab.label)
                }
                Spacer()
                Button {
                    isOpen = false
                    if let sessionID { store.workPanelOpenBySession[sessionID] = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("Close Work Panel", comment: ""))
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(Theme.barFill)

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)

            Group {
                if store.workPanelTab == .review {
                    WorkPanelReviewView()
                } else if store.workPanelTab == .context {
                    WorkPanelContextView()
                } else if store.workPanelTab == .files {
                    WorkPanelFilesView()
                } else if store.workPanelTab == .vcs {
                    WorkPanelVCSView()
                } else {
                    WorkPanelChildrenView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.sidebarFill)
        .frame(minWidth: 300, idealWidth: 380)
        .onAppear { Task { await store.loadDiff() } }
        .onChange(of: store.workPanelTab) { tab in
            Task {
                switch tab {
                case .files: break
                case .vcs: await store.loadVCS()
                case .children: await store.loadChildSessions()
                default: break
                }
            }
        }
    }
}

/// Review tab. This reuses the existing diff renderer but lives in a docked
/// surface instead of a modal sheet so users can keep the conversation visible.
struct WorkPanelReviewView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var server: ServerManager
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
            HStack(spacing: 8) {
                Text("+\(totalAdditions)")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("-\(totalDeletions)")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text(String(format: NSLocalizedString("Files: %lld", comment: ""), store.diffs.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("Filter files", text: $filterQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                }
                Button(NSLocalizedString(allExpanded ? "Collapse All" : "Expand All", comment: "")) {
                    withAnimation(.easeInOut(duration: 0.15)) { setAllExpanded(!allExpanded) }
                }
                .controlSize(.small)
                .disabled(store.diffs.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            if store.isLoadingDiff {
                VStack {
                    ProgressView().controlSize(.regular)
                    Text(NSLocalizedString("Loading diff…", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.diffs.isEmpty {
                VStack {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("No file changes in this session.", comment: ""))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredDiffs.isEmpty {
                VStack {
                    Text(NSLocalizedString("No files match the filter.", comment: ""))
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
                                    .onOpenFile {
                                        let candidate = URL(fileURLWithPath: diff.file)
                                        let resolved = candidate.path.hasPrefix("/")
                                            ? candidate
                                            : server.projectDirectory.appendingPathComponent(diff.file)
                                        guard FileManager.default.fileExists(atPath: resolved.path) else { return }
                                        NSWorkspace.shared.activateFileViewerSelecting([resolved])
                                    }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onChange(of: store.selectedSessionID) { _ in
            filterQuery = ""
            expandedFiles = []
            allExpanded = false
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

private struct WorkPanelFilesView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var server: ServerManager
    @State private var entries: [FileSystemEntry] = []
    @State private var path = ""
    @State private var preview: String?
    @State private var isLoading = false

    private var resolvedProjectPath: String {
        if let directory = store.currentDirectory, !directory.isEmpty {
            return directory
        }
        return server.projectDirectory.path
    }

    private var canNavigateToEntry: Bool {
        FileManager.default.fileExists(atPath: resolvedProjectPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField(NSLocalizedString("Folder path", comment: ""), text: $path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await load() } }
                Button(NSLocalizedString("Go", comment: "")) { Task { await load() } }
                    .controlSize(.small)
            }
            .padding(10)
            Divider()
            if isLoading {
                ProgressView().controlSize(.small).padding()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries.filter { SessionStore.isSearchablePath($0.path) }) { entry in
                        HStack(spacing: 6) {
                            Image(systemName: entry.isDirectory ? "folder" : "doc.text")
                                .foregroundStyle(entry.isDirectory ? .orange : .secondary)
                            Text((entry.path as NSString).lastPathComponent)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer()
                            if !entry.isDirectory {
                                Button {
                                    let resolved = URL(fileURLWithPath: resolvedProjectPath)
                                        .appendingPathComponent(entry.path)
                                    guard FileManager.default.fileExists(atPath: resolved.path) else { return }
                                    NSWorkspace.shared.activateFileViewerSelecting([resolved])
                                } label: {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .help(NSLocalizedString("Open in project", comment: ""))
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard canNavigateToEntry else { return }
                            if entry.isDirectory {
                                path = entry.path
                                Task { await load() }
                            } else {
                                Task { await loadPreview(entry.path) }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                    }
                }
                .padding(8)
                if canNavigateToEntry && entries.isEmpty && !isLoading {
                    Text(NSLocalizedString("No files in this folder.", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                } else if !canNavigateToEntry {
                    Text(NSLocalizedString("Project folder is unavailable.", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                }
            }
            if let preview {
                Divider()
                ScrollView {
                    Text(preview)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 220)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let api = store.apiForTools else { return }
        isLoading = true
        defer { isLoading = false }
        let directory = resolvedProjectPath
        if path.isEmpty { path = directory }
        let requestedPath = path
        do {
            guard FileManager.default.fileExists(atPath: directory) else {
                entries = []
                preview = nil
                store.setToolError(NSLocalizedString("Project folder is unavailable.", comment: ""))
                return
            }
            let response: FileListResponse = try await api.get(
                "api/fs/list",
                query: APIClient.locationQuery(
                    directory: directory,
                    workspace: nil
                ).merging(["path": path]) { _, new in new }
            )
            guard path == requestedPath else { return }
            entries = response.data.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
        } catch {
            guard path == requestedPath else { return }
            store.setToolError(UserFacingError.message(error))
        }
    }

    private func loadPreview(_ filePath: String) async {
        guard let api = store.apiForTools else { return }
        let directory = resolvedProjectPath
        do {
            guard FileManager.default.fileExists(atPath: directory) else {
                store.setToolError(NSLocalizedString("Project folder is unavailable.", comment: ""))
                return
            }
            let resolved = URL(fileURLWithPath: directory).appendingPathComponent(filePath).path
            if let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
               let size = attributes[.size] as? NSNumber, size.intValue > 256 * 1024 {
                preview = String(
                    format: NSLocalizedString("File is too large to preview (%lld bytes).", comment: ""),
                    size.int64Value
                )
                return
            }
            let data = try await api.getRaw(
                "api/fs/read/\(filePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filePath)",
                query: APIClient.locationQuery(directory: directory, workspace: nil)
            )
            preview = String(data: data, encoding: .utf8)
                ?? String(format: NSLocalizedString("Binary file (%lld bytes)", comment: ""), Int64(data.count))
        } catch {
            store.setToolError(UserFacingError.message(error))
        }
    }
}

private struct WorkPanelVCSView: View {
    @EnvironmentObject var store: SessionStore
    @State private var selectedPatch: VcsDiff?
    @State private var confirmingApply = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(format: NSLocalizedString("Changed files: %lld", comment: ""), Int64(store.vcsStatus.count)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(NSLocalizedString("Refresh", comment: "")) { Task { await store.loadVCS() } }
                    .controlSize(.small)
            }
            .padding(10)
            Divider()
            if store.vcsStatus.isEmpty {
                Text(NSLocalizedString("No working tree changes.", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                List(store.vcsStatus) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.status == "added" ? "plus.circle" : item.status == "deleted" ? "minus.circle" : "pencil.circle")
                            .foregroundStyle(item.status == "added" ? .green : item.status == "deleted" ? .red : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((item.file as NSString).lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                            Text(item.file)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text("+\(Int(item.additions)) -\(Int(item.deletions))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selectedPatch = store.vcsDiffs.first { $0.file == item.file } }
                }
                .listStyle(.plain)
            }
            if let patch = selectedPatch {
                Divider()
                HStack {
                    Text(patch.file)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Button(NSLocalizedString("Apply Patch", comment: "")) { confirmingApply = true }
                        .controlSize(.small)
                }
                .padding(8)
                ScrollView {
                    Text(patch.patch ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .alert(NSLocalizedString("Apply this patch to the working tree?", comment: ""), isPresented: $confirmingApply) {
                    Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
                    Button(NSLocalizedString("Apply", comment: ""), role: .destructive) {
                        Task { _ = await store.applyVCSPatch(patch.patch ?? "") }
                    }
                }
            }
        }
        .task { await store.loadVCS() }
    }
}

private struct WorkPanelChildrenView: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(NSLocalizedString("Child sessions", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(NSLocalizedString("Refresh", comment: "")) { Task { await store.loadChildSessions() } }
                    .controlSize(.small)
            }
            .padding(10)
            Divider()
            if store.childSessions.isEmpty {
                Text(NSLocalizedString("No child sessions.", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding()
            } else {
                List(store.childSessions) { session in
                    Button {
                        store.select(session.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.displayTitle)
                                .font(.system(size: 12, weight: .medium))
                            Text(session.id)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .task { await store.loadChildSessions() }
    }
}

/// Context inspector. The composer stays clean like Codex; token details live
/// here, split by what each number actually means:
/// - Context: the full request context of the latest turn vs. model limit.
/// - Generated: output + reasoning, i.e. what the model wrote this turn.
/// - Session totals: cumulative counters reported by the server.
struct WorkPanelContextView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var providers: ProviderStore
    @EnvironmentObject var server: ServerManager

    private var latestAssistant: MessageRecord? {
        store.messages.last(where: { $0.info.role == "assistant" })
    }

    private var latestTokens: MessageTokens? {
        if let tokens = latestAssistant?.info.tokens, tokens.contextUsed > 0 {
            return tokens
        }
        return store.messages.reversed()
            .first(where: { $0.info.role == "assistant" && ($0.info.tokens?.contextUsed ?? 0) > 0 })?
            .info.tokens
    }

    private var contextUsed: Double { latestTokens?.contextUsed ?? 0 }

    private var contextLimit: Double? {
        let effectiveModel = store.selectedModel
            ?? (store.serverDefaultModel.isEmpty ? nil : store.serverDefaultModel)
        return providers.contextLimit(for: effectiveModel)
    }

    private var contextRatio: Double? {
        guard let limit = contextLimit, limit > 0, contextUsed > 0 else { return nil }
        return min(max(contextUsed / limit, 0), 1)
    }

    private var contextTint: Color {
        guard let ratio = contextRatio else { return .secondary }
        if ratio > 0.85 { return .red }
        if ratio > 0.6 { return .orange }
        return .blue
    }

    private var latestGenerated: Double {
        guard let tokens = latestTokens else { return 0 }
        return (tokens.output ?? 0) + (tokens.reasoning ?? 0)
    }

    private var sessionGenerated: Double {
        guard let tokens = store.selectedSession?.tokens else { return 0 }
        return (tokens.output ?? 0) + (tokens.reasoning ?? 0)
    }

    private var sessionInput: Double {
        store.selectedSession?.tokens?.input ?? 0
    }

    private var sessionCached: Double {
        store.selectedSession?.tokens?.cache?.read ?? 0
    }

    private struct ResourceItem: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let symbol: String
        let isImage: Bool
        let urlString: String?
    }

    private var resourceItems: [ResourceItem] {
        var seen = Set<String>()
        var items: [ResourceItem] = []
        for message in store.messages {
            for part in message.parts where part.type == "file" {
                guard let urlString = part.url,
                      !urlString.isEmpty,
                      seen.insert(urlString).inserted else { continue }
                let filename = part.filename ?? (urlString as NSString).lastPathComponent
                items.append(ResourceItem(
                    title: filename.isEmpty ? NSLocalizedString("Image", comment: "attachment label") : filename,
                    detail: NSLocalizedString("Attachment", comment: "work panel resource"),
                    symbol: part.mime?.hasPrefix("image/") == true ? "photo" : "doc",
                    isImage: part.mime?.hasPrefix("image/") == true,
                    urlString: urlString
                ))
            }
        }
        for diff in store.diffs {
            // A file already listed as a prompt attachment must not appear
            // twice just because the review panel also reports it as a diff.
            guard seen.insert(diff.file).inserted else { continue }
            items.append(ResourceItem(
                title: (diff.file as NSString).lastPathComponent,
                detail: diff.file,
                symbol: "doc.text",
                isImage: false,
                urlString: diff.file
            ))
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("Context", comment: ""))
                .font(.headline)

            if contextUsed > 0 {
                contextCard
            } else {
                Text(NSLocalizedString("No token usage yet.", comment: ""))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel(NSLocalizedString("Latest reply", comment: "context panel section"))
                infoRow(
                    label: NSLocalizedString("Generated", comment: "tokens generated by the model"),
                    value: compactTokenCount(latestGenerated)
                )
            }

            if sessionGenerated > 0 || sessionInput > 0 || sessionCached > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel(NSLocalizedString("This session", comment: "context panel section"))
                    infoRow(label: NSLocalizedString("Generated", comment: "tokens generated by the model"), value: compactTokenCount(sessionGenerated))
                    infoRow(label: NSLocalizedString("New input", comment: "uncached input tokens"), value: compactTokenCount(sessionInput))
                    infoRow(label: NSLocalizedString("Cached input", comment: "cached input tokens"), value: compactTokenCount(sessionCached))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel(NSLocalizedString("Resources", comment: "work panel resource tab"))
                if resourceItems.isEmpty {
                    Text(NSLocalizedString("No files or images in this session.", comment: ""))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(resourceItems.prefix(8)) { item in
                        Button { openResource(item) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(item.detail)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(NSLocalizedString("Open in project", comment: ""))
                    }
                    if resourceItems.count > 8 {
                        Text(String(format: NSLocalizedString("+%lld more", comment: ""), resourceItems.count - 8))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Divider()

            infoRow(
                label: NSLocalizedString("Messages", comment: ""),
                value: "\(store.messages.count)"
            )
            infoRow(
                label: NSLocalizedString("File changes", comment: ""),
                value: "\(store.diffs.count)"
            )
            if let branch = store.vcsBranch, !branch.isEmpty {
                infoRow(label: NSLocalizedString("Branch", comment: ""), value: branch)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(NSLocalizedString("Context window", comment: "context panel label"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(contextReadout)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(contextTint)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if let ratio = contextRatio {
                        Capsule()
                            .fill(contextTint)
                            .frame(width: max(3, proxy.size.width * ratio))
                    }
                }
            }
            .frame(height: 5)
            Text(NSLocalizedString(
                "Full request context of the latest turn, including history and tool output — not the size of your message.",
                comment: "context panel explanation"
            ))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var contextReadout: String {
        if let limit = contextLimit, limit > 0, let ratio = contextRatio {
            return "\(compactTokenCount(contextUsed)) / \(compactTokenCount(limit)) · \(Int((ratio * 100).rounded()))%"
        }
        return compactTokenCount(contextUsed)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .font(.system(size: 13))
    }

    private func openResource(_ item: ResourceItem) {
        guard let value = item.urlString else { return }
        if value.hasPrefix("data:"), item.isImage {
            guard let comma = value.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(value[value.index(after: comma)...])),
                  let image = NSImage(data: data) else { return }
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("deveco-resource-\(UUID().uuidString).png")
            guard image.tiffRepresentation.flatMap({ try? $0.write(to: temp) }) != nil else { return }
            NSWorkspace.shared.activateFileViewerSelecting([temp])
            return
        }
        guard let url = URL(string: value), url.isFileURL else {
            if let webURL = URL(string: value), webURL.scheme?.hasPrefix("http") == true {
                NSWorkspace.shared.open(webURL)
            }
            return
        }
        let resolved = url.path.hasPrefix("/") ? url : server.projectDirectory.appendingPathComponent(value)
        guard FileManager.default.fileExists(atPath: resolved.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([resolved])
    }
}
