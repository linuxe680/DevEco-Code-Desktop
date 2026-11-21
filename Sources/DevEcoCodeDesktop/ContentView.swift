import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let openQuickSwitch = Notification.Name("com.deveco.openQuickSwitch")
    static let exportSelectedSession = Notification.Name("com.deveco.exportSelectedSession")
}

struct ContentView: View {
    /// Set by the extra `session` window scene to open a specific conversation.
    let initialSessionID: String?

    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var providers: ProviderStore
    @State private var section: Section = .sessions
    @State private var showSwitcher = false

    enum Section: String, CaseIterable, Identifiable {
        case sessions, providers

        var id: String { rawValue }

        var navigationLabel: String {
            switch self {
            case .sessions: return NSLocalizedString("Chat", comment: "")
            case .providers: return NSLocalizedString("Models", comment: "")
            }
        }

        var icon: String {
            switch self {
            case .sessions: return "bubble.left.and.bubble.right"
            case .providers: return "server.rack"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    ForEach(Section.allCases) { item in
                        Button {
                            withAnimation(.easeOut(duration: 0.12)) {
                                section = item
                            }
                        } label: {
                            Image(systemName: item.icon)
                                .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(section == item ? .primary : .secondary)
                            .frame(width: 28, height: 24)
                            .background(
                                section == item ? Theme.chipFill : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(item.navigationLabel)
                    }
                }
                .padding(2)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1, height: 18)

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusShortText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .help(statusText)

                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                    Text(server.projectDirectory.lastPathComponent)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 230, alignment: .leading)
                }
                .help(server.projectDirectory.path)

                if let branch = store.vcsBranch, !branch.isEmpty {
                    Text(branch)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.chipFill)
                        .clipShape(Capsule())
                }
                Spacer()
                Menu {
                    Button("Choose Folder…") { server.chooseFolder() }
                    if !server.recentProjects.isEmpty {
                        Divider()
                        ForEach(server.recentProjects, id: \.path) { url in
                            Button((url.path as NSString).lastPathComponent) {
                                server.openProject(url)
                            }
                        }
                    }
                } label: {
                    Label("Project", systemImage: "folder")
                        .font(.system(size: 14, weight: .medium))
                }
                .fixedSize()
                Button {
                    if server.state == .running {
                        server.stop()
                    } else {
                        server.start()
                    }
                } label: {
                    Image(systemName: server.state == .running ? "stop.circle" : "play.circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(server.state == .running ? "Stop Server" : "Start Server")
                Button {
                    Self.openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Theme.barFill)

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)

            if server.state != .running || store.isReconnecting {
                ConnectionStatusStrip()
                Divider()
            }

            Group {
                switch section {
                case .sessions:
                    HSplitView {
                        SessionListView()
                            .frame(minWidth: 230, idealWidth: 270, maxWidth: 330)
                        ChatView()
                            .frame(minWidth: 460)
                    }
                case .providers:
                    ProvidersView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if store.updateAvailable {
                Divider()
                HStack {
                    Image(systemName: "arrow.up.circle")
                        .foregroundStyle(.blue)
                    Text("A new deveco version is available.")
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") {
                        store.updateAvailable = false
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.bannerInfo)
            }
            if let error = store.errorMessage ?? providers.errorMessage ?? server.errorMessage {
                Divider()
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                    Button("Dismiss") {
                        store.errorMessage = nil
                        providers.errorMessage = nil
                        server.errorMessage = nil
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.bannerWarning)
            }
        }
        .navigationTitle(store.selectedSession?.displayTitle ?? "DevEco Code Desktop")
        .background(WindowChromeConfigurator())
        .onAppear {
            if server.state == .stopped && AppSettings.autoStartServer {
                server.start()
            }
            if let initialSessionID, !initialSessionID.isEmpty {
                store.select(initialSessionID)
            }
            store.serverDefaultModel = providers.defaultModel
            applyServerDefaultModelIfNeeded()
        }
        .onChange(of: providers.defaultModel) { _ in
            store.serverDefaultModel = providers.defaultModel
            applyServerDefaultModelIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openQuickSwitch)) { _ in
            showSwitcher = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportSelectedSession)) { _ in
            exportSession(store.selectedSession)
        }
        .sheet(isPresented: $showSwitcher) {
            QuickSwitchView()
        }
        .onChange(of: store.pendingPermissions.count) { _ in
            updateDockBadge()
        }
        .onChange(of: store.pendingQuestions.count) { _ in
            updateDockBadge()
        }
        .overlay {
            if server.failureReason == .devecoMissing {
                SetupCard(
                    onChooseBinary: { chooseBinary() },
                    onRetry: { server.start() },
                    onOpenSettings: { Self.openSettings() }
                )
                .frame(maxWidth: 460)
            }
        }
        .onChange(of: server.baseURL) { url in
            if let url {
                store.connect(baseURL: url)
                providers.connect(baseURL: url)
            } else {
                store.disconnect()
                providers.disconnect()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            server.recheckHealthIfNeeded()
        }
    }

    private static func openSettings() {
        // The Settings scene adds a menu item automatically; this opens it
        // from the toolbar gear on every supported macOS version.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func exportSession(_ session: Session?) {
        guard let session else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = session.displayTitle.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await store.export(session, to: url)
            } catch {
                store.errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func updateDockBadge() {
        let pending = store.pendingPermissions.count + store.pendingQuestions.count
        NSApp.dockTile.badgeLabel = pending > 0 ? "\(pending)" : nil
    }

    /// Show the server's configured model in the picker instead of leaving it
    /// on "Server default" once the provider list has loaded.
    private func applyServerDefaultModelIfNeeded() {
        guard store.selectedModel == nil else { return }
        let candidate = providers.defaultModel
        guard !candidate.isEmpty,
              providers.allModelChoices.contains(where: { $0.id == candidate }) else { return }
        store.selectedModel = candidate
    }

    private func chooseBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Binary"
        panel.message = "Select the deveco CLI executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppSettings.devecoPath = url.path
        server.start()
    }

    private var statusColor: Color {
        switch server.state {
        case .running: return .green
        case .starting: return .orange
        case .failed: return .red
        case .stopped: return .gray
        }
    }

    private var statusText: String {
        let endpoint = "127.0.0.1:\(server.port)"
        switch server.state {
        case .running: return String(format: NSLocalizedString("Connected · %@", comment: ""), endpoint)
        case .starting: return String(format: NSLocalizedString("Starting · %@", comment: ""), endpoint)
        case .failed: return NSLocalizedString("Failed", comment: "")
        case .stopped: return NSLocalizedString("Stopped", comment: "")
        }
    }

    private var statusShortText: String {
        switch server.state {
        case .running: return NSLocalizedString("Connected", comment: "")
        case .starting: return NSLocalizedString("Starting…", comment: "")
        case .failed: return NSLocalizedString("Failed", comment: "")
        case .stopped: return NSLocalizedString("Stopped", comment: "")
        }
    }
}

/// Matches the native titlebar to the Codex-style chrome instead of letting
/// AppKit draw its lighter default dark strip above the app's own toolbar.
private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.windowChromeNSColor
        window.titlebarSeparatorStyle = .none
    }
}

/// Single strip for every server-side fault state: starting, failed, stopped,
/// or event-stream reconnecting. The Codex-style contract — always say what is
/// wrong and offer the recovery action inline.
private struct ConnectionStatusStrip: View {
    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var store: SessionStore

    var body: some View {
        HStack(spacing: 10) {
            switch (server.state, store.isReconnecting) {
            case (_, true):
                ProgressView()
                    .controlSize(.small)
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
                Text("Connection lost — reconnecting…")
                    .font(.system(size: 14, weight: .medium))
                Text(String(format: NSLocalizedString("Attempt %d", comment: ""), max(store.reconnectAttemptCount, 1)))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            case (.starting, false):
                ProgressView()
                    .controlSize(.small)
                Text("Starting the deveco server…")
                    .font(.system(size: 14, weight: .medium))
                Text("127.0.0.1:\(server.port)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            case (.failed, false):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.failureReason?.label ?? NSLocalizedString("Server failed", comment: ""))
                        .font(.system(size: 14, weight: .semibold))
                    if let message = server.errorMessage {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Button("Retry") { server.start() }
                    .controlSize(.small)
                Button("Show Log") {
                    NSWorkspace.shared.activateFileViewerSelecting([ServerManager.logFileURL])
                }
                .controlSize(.small)
            case (.stopped, false):
                Image(systemName: "pause.circle")
                    .foregroundStyle(.secondary)
                Text("Server stopped")
                    .font(.system(size: 14, weight: .medium))
                Button("Start Server") { server.start() }
                    .controlSize(.small)
            case (.running, false):
                EmptyView()
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(server.state == .failed ? Theme.bannerError : Theme.bannerInfo)
        .animation(.easeInOut(duration: 0.15), value: server.state)
        .animation(.easeInOut(duration: 0.15), value: store.isReconnecting)
    }
}

/// ⌘K palette: type-to-filter active sessions, Enter opens the top hit.
struct QuickSwitchView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    private var results: [Session] {
        let active = store.sessions.filter { !$0.isArchived }
        if query.isEmpty {
            return active.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        }
        return active.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query)
                || ($0.directory ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Switch to session…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit {
                        if let first = results.first {
                            commit(first)
                        }
                    }
            }
            .padding(16)

            Divider()

            if results.isEmpty {
                VStack {
                    Text("No matching sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { session in
                    Button { commit(session) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.displayTitle)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                if let directory = session.directory {
                                    Text((directory as NSString).lastPathComponent)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let indicator = store.indicator(for: session.id) {
                                SessionIndicatorBadge(indicator: indicator)
                            }
                            if session.id == store.selectedSessionID {
                                Image(systemName: "checkmark")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 480, height: 400)
        .background(Theme.chromeFill)
        .onAppear { fieldFocused = true }
    }

    private func commit(_ session: Session) {
        store.select(session.id)
        dismiss()
    }
}

/// Shown when the deveco CLI cannot be found: guides the user through setup.
private struct SetupCard: View {
    var onChooseBinary: () -> Void
    var onRetry: () -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Set up the deveco CLI", systemImage: "wrench.and.screwdriver")
                .font(.title3.weight(.semibold))

            Text("The app manages a local deveco server but couldn't find the CLI on this Mac.")
                .font(.callout)

            VStack(alignment: .leading, spacing: 8) {
                step(1, "Install it globally, e.g. npm i -g deveco")
                step(2, "Or point the app at an existing binary below")
                step(3, "Then pick a project folder and start chatting")
            }

            HStack {
                Button("Choose Binary…", action: onChooseBinary)
                    .keyboardShortcut(.defaultAction)
                Button("Retry", action: onRetry)
                Button("Open Settings…", action: onOpenSettings)
            }
        }
        .padding(24)
        .background(Theme.chromeFill)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.3)))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .frame(width: 18, height: 18)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Circle())
            Text(text)
                .font(.callout)
        }
    }
}
