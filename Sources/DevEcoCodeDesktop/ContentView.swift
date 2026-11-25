import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let openQuickSwitch = Notification.Name("com.deveco.openQuickSwitch")
    static let exportSelectedSession = Notification.Name("com.deveco.exportSelectedSession")
    static let openWorkPanel = Notification.Name("com.deveco.openWorkPanel")
    static let openContextPanel = Notification.Name("com.deveco.openContextPanel")
    static let openConversationSearch = Notification.Name("com.deveco.openConversationSearch")
}

struct ContentView: View {

    @EnvironmentObject var server: ServerManager
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var providers: ProviderStore
    @State private var section: AppSection = .sessions
    @State private var showSwitcher = false
    @State private var workPanelOpen = false
    @State private var showSearch = false

    var body: some View {
        VStack(spacing: 0) {
            if server.state != .running || store.isReconnecting || store.streamRejected {
                ConnectionStatusStrip()
                Divider()
            }

            Group {
                switch section {
                case .sessions:
                    HSplitView {
                        SessionListView(section: $section)
                            .frame(minWidth: 230, idealWidth: 270, maxWidth: 330)
                        ChatView(
                            workPanelOpen: $workPanelOpen,
                            showSearch: $showSearch,
                            section: $section
                        )
                            .frame(minWidth: 460)
                        if workPanelOpen {
                            WorkPanelView(isOpen: $workPanelOpen)
                        }
                    }
                    .ignoresSafeArea(.container, edges: .top)
                case .providers:
                    ProvidersView(section: $section)
                        .ignoresSafeArea(.container, edges: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if store.updateAvailable {
                Divider()
                HStack {
                    Image(systemName: "arrow.up.circle")
                        .foregroundStyle(.blue)
                    Text(NSLocalizedString("A new deveco version is available.", comment: ""))
                        .font(.caption)
                    Spacer()
                    Button(NSLocalizedString("Dismiss", comment: "")) {
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
                    // The persistent status strip owns the Retry action for a
                    // rejected stream; the banner only carries the diagnosis.
                    Button(NSLocalizedString("Dismiss", comment: "")) {
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
        // Pull each pane's own top row up under the hidden titlebar so the
        // traffic lights share it — no separate full-width strip above.
        .ignoresSafeArea(.container, edges: .top)
        .background(WindowChromeConfigurator())
        .onAppear {
            if server.state == .stopped && AppSettings.autoStartServer {
                server.start()
            }
            store.serverDefaultModel = providers.defaultModel
            store.availableModels = Set(providers.allModelChoices.map(\.id))
            applyServerDefaultModelIfNeeded()
        }
        .onChange(of: providers.defaultModel) { _ in
            store.serverDefaultModel = providers.defaultModel
            store.availableModels = Set(providers.allModelChoices.map(\.id))
            applyServerDefaultModelIfNeeded()
        }
        .onChange(of: providers.allModelChoices) { _ in
            store.availableModels = Set(providers.allModelChoices.map(\.id))
            store.repairStaleModelSelection()
            applyServerDefaultModelIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openQuickSwitch)) { _ in
            showSwitcher = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportSelectedSession)) { _ in
            exportSession(store.selectedSession)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWorkPanel)) { _ in
            workPanelOpen = true
            store.setWorkPanelTab(.review)
            if let id = store.selectedSessionID {
                store.workPanelOpenBySession[id] = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openContextPanel)) { _ in
            workPanelOpen = true
            store.setWorkPanelTab(.context)
            if let id = store.selectedSessionID {
                store.workPanelOpenBySession[id] = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openConversationSearch)) { _ in
            section = .sessions
            showSearch = true
        }
        .onChange(of: store.selectedSessionID) { id in
            guard let id else {
                workPanelOpen = false
                return
            }
            workPanelOpen = store.workPanelOpenBySession[id] ?? false
        }
        .sheet(isPresented: $showSwitcher) {
            GlobalCommandPaletteView()
        }
        .onChange(of: store.pendingPermissions.count) { _ in
            updateDockBadge()
        }
        .onChange(of: store.pendingQuestions.count) { _ in
            updateDockBadge()
        }
        .onAppear { updateDockBadge() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
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

    static func openSettings() {
        // The Settings scene adds a menu item automatically; this opens it
        // from the toolbar gear on every supported macOS version. macOS 11/12
        // only responds to the older preferences selector.
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            return
        }
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
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
                store.errorMessage = String(
                    format: NSLocalizedString("Export failed: %@", comment: ""),
                    error.localizedDescription
                )
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
        panel.prompt = NSLocalizedString("Use This Binary", comment: "")
        panel.message = NSLocalizedString("Select the deveco CLI executable", comment: "")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppSettings.devecoPath = url.path
        server.start()
    }

}

/// Matches the native titlebar to the Codex-style chrome instead of letting
/// AppKit draw its lighter default dark strip above the app's own toolbar.
private struct WindowChromeConfigurator: NSViewRepresentable {
    private final class ConfiguratorView: NSView {
        weak var configuredWindow: NSWindow?
    }

    func makeNSView(context: Context) -> NSView {
        let view = ConfiguratorView(frame: .zero)
        DispatchQueue.main.async { [weak view] in self.configure(view?.window) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak view] in
            self.configure(view?.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? ConfiguratorView, view.configuredWindow !== view.window else { return }
        view.configuredWindow = view.window
        configure(view.window)
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        if let view = window.contentView as? ConfiguratorView {
            view.configuredWindow = window
        }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.windowChromeNSColor
        window.titlebarSeparatorStyle = .none
        // Codex has no redundant title label above its toolbar: the session
        // title lives in the sidebar/toolbar only. Hide the AppKit title
        // entirely so long prompts never repeat in this dead strip.
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.toolbar?.displayMode = .iconOnly
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
            // A rejected stream is a connection state, not a one-off toast:
            // keep a Retry affordance here so dismissing the error banner
            // cannot strand the app with no way to reconnect.
            if store.streamRejected {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .foregroundStyle(.orange)
                Text(NSLocalizedString("Event stream rejected", comment: ""))
                    .font(.system(size: 14, weight: .medium))
                Button(NSLocalizedString("Retry", comment: "")) { store.retryStreamConnection() }
                    .controlSize(.small)
            } else {
                switch (server.state, store.isReconnecting) {
                case (_, true):
                    ProgressView()
                        .controlSize(.small)
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                    Text(NSLocalizedString("Connection lost — reconnecting…", comment: ""))
                        .font(.system(size: 14, weight: .medium))
                    Text(String(format: NSLocalizedString("Attempt %d", comment: ""), max(store.reconnectAttemptCount, 1)))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                case (.starting, false):
                    ProgressView()
                        .controlSize(.small)
                    Text(NSLocalizedString("Starting the deveco server…", comment: ""))
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
                    Button(NSLocalizedString("Retry", comment: "")) { server.start() }
                        .controlSize(.small)
                    Button(NSLocalizedString("Show Log", comment: "")) {
                        NSWorkspace.shared.activateFileViewerSelecting([ServerManager.logFileURL])
                    }
                    .controlSize(.small)
                case (.stopped, false):
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("Server stopped", comment: ""))
                        .font(.system(size: 14, weight: .medium))
                    Button(NSLocalizedString("Start Server", comment: "")) { server.start() }
                        .controlSize(.small)
                case (.running, false):
                    EmptyView()
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(server.state == .failed ? Theme.bannerError : Theme.bannerInfo)
        .animation(.easeInOut(duration: 0.15), value: server.state)
        .animation(.easeInOut(duration: 0.15), value: store.isReconnecting)
        .animation(.easeInOut(duration: 0.15), value: store.streamRejected)
    }
}

/// Shown when the deveco CLI cannot be found: guides the user through setup.
private struct SetupCard: View {
    var onChooseBinary: () -> Void
    var onRetry: () -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(NSLocalizedString("Set up the deveco CLI", comment: ""), systemImage: "wrench.and.screwdriver")
                .font(.title3.weight(.semibold))

            Text(NSLocalizedString("The app manages a local deveco server but couldn't find the CLI on this Mac.", comment: ""))
                .font(.callout)

            VStack(alignment: .leading, spacing: 8) {
                step(1, NSLocalizedString("Install it globally, e.g. npm i -g @deveco/deveco-code@stable", comment: ""))
                step(2, "Or point the app at an existing binary below")
                step(3, "Then pick a project folder and start chatting")
            }

            HStack {
                Button(NSLocalizedString("Choose Binary…", comment: ""), action: onChooseBinary)
                    .keyboardShortcut(.defaultAction)
                Button(NSLocalizedString("Retry", comment: ""), action: onRetry)
                Button(NSLocalizedString("Open Settings…", comment: ""), action: onOpenSettings)
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
