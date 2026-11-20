import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let server = ServerManager()
    private weak var store: SessionStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Re-assert the bundle icon at runtime. The Dock otherwise keeps the
        // previous icon for this bundle id until a full logout/restart.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }

    func attach(store: SessionStore) {
        self.store = store
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Don't leave the deveco serve child process orphaned, unless the
        // user opted to keep it running for the next launch.
        if AppSettings.quitBehavior == .stopServer {
            server.stop()
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let newSession = NSMenuItem(
            title: NSLocalizedString("New Session", comment: ""),
            action: #selector(newSessionFromDock),
            keyEquivalent: ""
        )
        newSession.target = self
        menu.addItem(newSession)
        let quickSwitch = NSMenuItem(
            title: NSLocalizedString("Quick Switch…", comment: ""),
            action: #selector(quickSwitchFromDock),
            keyEquivalent: ""
        )
        quickSwitch.target = self
        menu.addItem(quickSwitch)
        return menu
    }

    @objc private func newSessionFromDock() {
        store?.createSession()
    }

    @objc private func quickSwitchFromDock() {
        NotificationCenter.default.post(name: .openQuickSwitch, object: nil)
    }
}

/// Owns the server so the menu label stays in sync with its state.
private struct ServerCommands: Commands {
    @ObservedObject var server: ServerManager

    var body: some Commands {
        CommandMenu("Server") {
            Button(server.state == .running
                   ? NSLocalizedString("Stop Server", comment: "")
                   : NSLocalizedString("Start Server", comment: "")) {
                if server.state == .running {
                    server.stop()
                } else {
                    server.start()
                }
            }
        }
    }
}

@main
struct DevEcoCodeDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: SessionStore
    @StateObject private var providers: ProviderStore

    init() {
        AppSettings.registerDefaults()
        let store = SessionStore()
        let providers = ProviderStore()
        _store = StateObject(wrappedValue: store)
        _providers = StateObject(wrappedValue: providers)
        appDelegate.attach(store: store)
        // The toggle requests authorization when enabled; repeat once at
        // launch for users who enabled it before granting permission.
        if AppSettings.notifyOnComplete {
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.server)
                .environmentObject(store)
                .environmentObject(providers)
                .frame(minWidth: 940, minHeight: 620)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session") { store.createSession() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Quick Switch…") {
                    NotificationCenter.default.post(name: .openQuickSwitch, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                Button("Choose Project Folder…") { appDelegate.server.chooseFolder() }
                Divider()
                Button("Export Session…") {
                    NotificationCenter.default.post(name: .exportSelectedSession, object: nil)
                }
            }
        }
        .commands {
            ServerCommands(server: appDelegate.server)
        }

        Settings {
            SettingsView()
                .environmentObject(appDelegate.server)
                .environmentObject(store)
                .environmentObject(providers)
        }
    }
}
