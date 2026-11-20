import Foundation

enum QuitBehavior: String, CaseIterable, Identifiable {
    case stopServer, keepRunning

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stopServer: return "Stop server"
        case .keepRunning: return "Keep running"
        }
    }
}

/// User-facing settings. Simple keys live in UserDefaults and are read
/// directly wherever needed; views bind with @AppStorage(AppSettings.Keys.*).
enum AppSettings {
    enum Keys {
        static let devecoPath = "devecoExecutablePath"
        static let autoStartServer = "autoStartServer"
        static let basePort = "basePort"
        static let quitBehavior = "quitBehavior"
        static let sendOnEnter = "sendOnEnter"
        static let chatFontSize = "chatFontSize"
        static let chatFontSizeCodexMatched = "chatFontSizeCodexMatched"
        static let autoScroll = "autoScroll"
        static let expandThinking = "expandThinking"
        static let defaultSessionModel = "defaultSessionModel"
        static let notifyOnComplete = "notifyOnComplete"
        static let playSoundOnComplete = "playSoundOnComplete"
        static let promptHistory = "promptHistory"
        static let sessionModels = "sessionModels"
        static let sessionVariants = "sessionVariants"
        static let chatFontMigration = "chatFontSizeDefaultMigratedTo16"
    }

    static func registerDefaults() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.autoStartServer: true,
            Keys.basePort: 4096,
            Keys.quitBehavior: QuitBehavior.stopServer.rawValue,
            Keys.sendOnEnter: true,
            Keys.chatFontSize: 15.0,
            Keys.autoScroll: true,
            Keys.expandThinking: false,
            Keys.defaultSessionModel: "",
            Keys.devecoPath: "",
            Keys.notifyOnComplete: false,
            Keys.playSoundOnComplete: false,
        ])
        // The previous defaults were too small on modern displays. Move
        // existing installs to 15pt once, without overriding later user
        // choices on every launch.
        if !defaults.bool(forKey: Keys.chatFontMigration) {
            if let stored = defaults.object(forKey: Keys.chatFontSize) as? Double,
               stored <= 15.0 {
                defaults.set(15.0, forKey: Keys.chatFontSize)
            }
            defaults.set(true, forKey: Keys.chatFontMigration)
        }
        // Codex's CSS says 16px, but its CJK fallback renders optically smaller
        // than AppKit's 16pt. 15pt matches the on-screen size; users can still
        // pick 16pt from the Aa menu afterwards.
        if !defaults.bool(forKey: Keys.chatFontSizeCodexMatched) {
            if let stored = defaults.object(forKey: Keys.chatFontSize) as? Double,
               stored == 16.0 {
                defaults.set(15.0, forKey: Keys.chatFontSize)
            }
            defaults.set(true, forKey: Keys.chatFontSizeCodexMatched)
        }
    }

    static var devecoPath: String {
        get { UserDefaults.standard.string(forKey: Keys.devecoPath) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.devecoPath) }
    }

    static var autoStartServer: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.autoStartServer) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.autoStartServer) }
    }

    static var basePort: Int {
        get { UserDefaults.standard.integer(forKey: Keys.basePort) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.basePort) }
    }

    static var quitBehavior: QuitBehavior {
        get { QuitBehavior(rawValue: UserDefaults.standard.string(forKey: Keys.quitBehavior) ?? "") ?? .stopServer }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.quitBehavior) }
    }

    static var sendOnEnter: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.sendOnEnter) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.sendOnEnter) }
    }

    static var chatFontSize: Double {
        get { UserDefaults.standard.double(forKey: Keys.chatFontSize) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.chatFontSize) }
    }

    static var autoScroll: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.autoScroll) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.autoScroll) }
    }

    static var expandThinking: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.expandThinking) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.expandThinking) }
    }

    /// App-side default model ("providerID/modelID") preselected for new
    /// sessions. Empty means the server's configured default is used.
    static var defaultSessionModel: String {
        get { UserDefaults.standard.string(forKey: Keys.defaultSessionModel) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.defaultSessionModel) }
    }

    static var notifyOnComplete: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.notifyOnComplete) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.notifyOnComplete) }
    }

    static var playSoundOnComplete: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.playSoundOnComplete) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.playSoundOnComplete) }
    }

    /// Recently sent prompts (oldest first, most recent last); capped.
    static var promptHistory: [String] {
        get { UserDefaults.standard.stringArray(forKey: Keys.promptHistory) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(50)), forKey: Keys.promptHistory) }
    }

    /// Per-session model choice ("providerID/modelID"), keyed by session id.
    /// Empty string means "Server default".
    static var sessionModels: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Keys.sessionModels) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.sessionModels) }
    }

    /// Per-session reasoning-effort variant, keyed by session id.
    static var sessionVariants: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Keys.sessionVariants) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.sessionVariants) }
    }
}
