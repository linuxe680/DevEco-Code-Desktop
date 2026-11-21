import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let server = ServerManager()
    /// 强引用：Dock 菜单的"新建会话"必须在 Scene 生命周期之外始终可用。
    private var store: SessionStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.applyAppearanceOverride()
        // Re-assert the bundle icon at runtime. The Dock otherwise keeps the
        // previous icon for this bundle id until a full logout/restart.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }

    func attach(store: SessionStore) {
        self.store = store
        // Notification taps route back to the session they came from.
        UNUserNotificationCenter.current().delegate = self
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

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionID = response.notification.request.content.userInfo["sessionID"] as? String
        Task { @MainActor in
            if let sessionID, !sessionID.isEmpty {
                NSApp.activate(ignoringOtherApps: true)
                store?.select(sessionID)
            }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // In-app generation/permission state is already visible; suppress
        // duplicate banners while the user is looking at the app.
        completionHandler([])
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

/// Extra session windows share the same store; the selected session is
/// restored from the window's `value` when it opens.
private struct SessionWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var store: SessionStore

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(NSLocalizedString("Open Session in New Window", comment: "")) {
                guard let id = store.selectedSessionID else { return }
                openWindow(id: "session", value: id)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
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
        AppSettings.applyLanguageOverride()
        AppSettings.applyAppearanceOverride()
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
            ContentView(initialSessionID: nil)
                .environmentObject(appDelegate.server)
                .environmentObject(store)
                .environmentObject(providers)
                .frame(minWidth: 940, minHeight: 620)
        }
        WindowGroup(id: "session", for: String.self) { sessionID in
            ContentView(initialSessionID: sessionID.wrappedValue)
                .environmentObject(appDelegate.server)
                .environmentObject(store)
                .environmentObject(providers)
                .frame(minWidth: 940, minHeight: 620)
        }
        .commands {
            SessionWindowCommands(store: store)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button(NSLocalizedString("New Session", comment: "")) { store.createSession() }
                    .keyboardShortcut("n", modifiers: .command)
                Button(NSLocalizedString("Quick Switch…", comment: "")) {
                    NotificationCenter.default.post(name: .openQuickSwitch, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
                Button(NSLocalizedString("Choose Project Folder…", comment: "")) { appDelegate.server.chooseFolder() }
                Divider()
                Button(NSLocalizedString("Export Session…", comment: "")) {
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
