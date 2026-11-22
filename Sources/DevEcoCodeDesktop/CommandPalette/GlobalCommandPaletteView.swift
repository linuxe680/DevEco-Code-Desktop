import SwiftUI
import AppKit

/// ⌘K command palette. Results are assembled locally from existing store and
/// server state; no new service calls or protocols are required.
@MainActor
struct GlobalCommandPaletteView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var server: ServerManager
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    private let commands: [CommandAction]

    init() {
        self.commands = CommandAction.defaults
    }

    init(commands: [CommandAction]) {
        self.commands = commands
    }

    private var needle: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var filteredCommands: [CommandAction] {
        guard !needle.isEmpty else { return commands }
        return commands.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || $0.keywords.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    var filteredSessions: [Session] {
        Self.filteredSessions(store.sessions, query: query)
    }

    var recentProjects: [URL] {
        Self.filteredProjects(server.recentProjects, query: query)
    }

    static func filteredSessions(_ sessions: [Session], query: String) -> [Session] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = sessions.filter { !$0.isSubagent }
        let matched = needle.isEmpty
            ? visible
            : visible.filter {
                $0.displayTitle.localizedCaseInsensitiveContains(needle)
                    || ($0.directory ?? "").localizedCaseInsensitiveContains(needle)
            }
        return matched.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    static func filteredProjects(_ projects: [URL], query: String) -> [URL] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return projects }
        return projects.filter { $0.path.localizedCaseInsensitiveContains(needle) }
    }

    private var hasResults: Bool {
        !filteredCommands.isEmpty || !filteredSessions.isEmpty || !recentProjects.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search sessions, projects, and commands…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { runTopResult() }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)

            Divider()

            if !hasResults {
                VStack {
                    Text(NSLocalizedString("No matching results", comment: ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !filteredCommands.isEmpty {
                        Section(NSLocalizedString("Commands", comment: "")) {
                            ForEach(filteredCommands) { command in
                                Button { run(command) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: command.symbol)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(command.title)
                                                .font(.system(size: 13, weight: .medium))
                                            if !command.subtitle.isEmpty {
                                                Text(command.subtitle)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Text(command.shortcut)
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !filteredSessions.isEmpty {
                        Section(NSLocalizedString("Sessions", comment: "")) {
                            ForEach(filteredSessions) { session in
                                Button { commit(session) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "bubble.left")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(session.displayTitle)
                                                .font(.system(size: 13, weight: .medium))
                                            if let directory = session.directory {
                                                Text(directory)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                        }
                                        Spacer()
                                        if let indicator = store.indicator(for: session.id) {
                                            SessionIndicatorBadge(indicator: indicator)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !recentProjects.isEmpty {
                        Section(NSLocalizedString("Projects", comment: "")) {
                            ForEach(recentProjects, id: \.path) { project in
                                Button { commit(project) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "folder")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(project.lastPathComponent)
                                                .font(.system(size: 13, weight: .medium))
                                            Text(project.path)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 560, height: 460)
        .background(Theme.chromeFill)
        .onAppear { fieldFocused = true }
    }

    private func runTopResult() {
        if let command = filteredCommands.first {
            run(command)
        } else if let session = filteredSessions.first {
            commit(session)
        } else if let project = recentProjects.first {
            commit(project)
        }
    }

    private func run(_ command: CommandAction) {
        dismiss()
        command.run(store, server)
    }

    private func commit(_ session: Session) {
        store.select(session.id)
        dismiss()
    }

    private func commit(_ project: URL) {
        server.openProject(project)
        dismiss()
    }
}

@MainActor
struct CommandAction: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let symbol: String
    let shortcut: String
    let keywords: [String]
    let run: (SessionStore, ServerManager) -> Void

    static let defaults: [CommandAction] = [
        CommandAction(
            title: NSLocalizedString("New Session", comment: ""),
            subtitle: NSLocalizedString("Start a new conversation in the current project", comment: ""),
            symbol: "square.and.pencil",
            shortcut: "⌘N",
            keywords: ["new", "create", "session", "chat"],
            run: { store, _ in store.createSession() }
        ),
        CommandAction(
            title: NSLocalizedString("Choose Project Folder…", comment: ""),
            subtitle: NSLocalizedString("Switch the running server to another project", comment: ""),
            symbol: "folder",
            shortcut: "",
            keywords: ["project", "folder", "open", "workspace"],
            run: { _, server in server.chooseFolder() }
        ),
        CommandAction(
            title: NSLocalizedString("Export Session…", comment: ""),
            subtitle: NSLocalizedString("Export the selected transcript as Markdown", comment: ""),
            symbol: "square.and.arrow.up",
            shortcut: "",
            keywords: ["export", "markdown", "session", "transcript"],
            run: { _, _ in
                NotificationCenter.default.post(name: .exportSelectedSession, object: nil)
            }
        ),
        CommandAction(
            title: NSLocalizedString("Start Server", comment: ""),
            subtitle: NSLocalizedString("Start the local deveco serve process", comment: ""),
            symbol: "play.circle",
            shortcut: "",
            keywords: ["server", "start", "serve"],
            run: { _, server in
                if server.state != .running { server.start() }
            }
        ),
        CommandAction(
            title: NSLocalizedString("Stop Server", comment: ""),
            subtitle: NSLocalizedString("Stop the local deveco serve process", comment: ""),
            symbol: "stop.circle",
            shortcut: "",
            keywords: ["server", "stop", "serve"],
            run: { _, server in
                if server.state == .running { server.stop() }
            }
        ),
        CommandAction(
            title: NSLocalizedString("Settings…", comment: ""),
            subtitle: NSLocalizedString("Open application settings", comment: ""),
            symbol: "gearshape",
            shortcut: "⌘,",
            keywords: ["settings", "preferences", "providers", "permissions"],
            run: { _, _ in
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        ),
    ]
}
