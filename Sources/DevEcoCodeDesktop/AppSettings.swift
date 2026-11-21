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
        static let autoScroll = "autoScroll"
        static let expandThinking = "expandThinking"
        static let defaultSessionModel = "defaultSessionModel"
        static let notifyOnComplete = "notifyOnComplete"
        static let playSoundOnComplete = "playSoundOnComplete"
        static let promptHistory = "promptHistory"
        static let sessionModels = "sessionModels"
        static let sessionVariants = "sessionVariants"
        static let settingsVersion = "settingsVersion"
        static let pinnedSessionIDs = "pinnedSessionIDs"
        static let recentModels = "recentModelChoices"
        static let appLanguage = "appLanguage"
        static let savedPermissionRules = "savedPermissionRules"
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
        // One-shot migrations, gated by a single version marker so new rules
        // append instead of stacking one-off flag keys. v1: older defaults
        // were too small on modern displays, and Codex's 16px CSS renders
        // optically smaller than AppKit 16pt (CJK fallback) — both land on
        // 15pt once, without overriding later user choices.
        if defaults.integer(forKey: Keys.settingsVersion) < 1 {
            if let stored = defaults.object(forKey: Keys.chatFontSize) as? Double,
               stored <= 16.0 {
                defaults.set(15.0, forKey: Keys.chatFontSize)
            }
            defaults.set(1, forKey: Keys.settingsVersion)
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

    /// UI language: forced Chinese by default, with English and follow-system
    /// options. Applies through the per-app AppleLanguages override.
    static var appLanguage: String {
        get { UserDefaults.standard.string(forKey: Keys.appLanguage) ?? "zh-Hans" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.appLanguage) }
    }

    static func applyLanguageOverride() {
        let language = appLanguage
        if language == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language], forKey: "AppleLanguages")
        }
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

    /// Client-side pinned session ids (no server field), in pin order.
    static var pinnedSessionIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: Keys.pinnedSessionIDs) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.pinnedSessionIDs) }
    }

    /// Cross-session "always allow" rules. Each rule is "permission|pattern";
    /// the deveco server only honors saved permissions in-process, so the app
    /// keeps its own durable copy and auto-approves matching requests.
    static var savedPermissionRules: [String] {
        get { UserDefaults.standard.stringArray(forKey: Keys.savedPermissionRules) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.savedPermissionRules) }
    }

    /// Most recently picked model ids ("providerID/modelID"), newest first.
    static var recentModels: [String] {
        get { UserDefaults.standard.stringArray(forKey: Keys.recentModels) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.recentModels) }
    }

    /// Records a model pick: deduped, newest first, capped at six entries.
    @discardableResult
    static func rememberRecentModel(_ id: String) -> [String] {
        var recents = recentModels.filter { $0 != id }
        recents.insert(id, at: 0)
        recents = Array(recents.prefix(6))
        recentModels = recents
        return recents
    }
}
