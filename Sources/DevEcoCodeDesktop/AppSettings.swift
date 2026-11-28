import Foundation
import AppKit

enum QuitBehavior: String, CaseIterable, Identifiable {
    case stopServer, keepRunning

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stopServer: return NSLocalizedString("Stop server", comment: "")
        case .keepRunning: return NSLocalizedString("Keep server running", comment: "")
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return NSLocalizedString("Follow system", comment: "")
        case .light: return NSLocalizedString("Light", comment: "")
        case .dark: return NSLocalizedString("Dark", comment: "")
        }
    }
}

enum SessionSortOrder: String, CaseIterable, Identifiable {
    case recent, title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: return NSLocalizedString("Last updated", comment: "session sort")
        case .title: return NSLocalizedString("Title", comment: "session sort")
        }
    }

    func areInIncreasingOrder(_ lhs: Session, _ rhs: Session) -> Bool {
        switch self {
        case .recent:
            let left = lhs.updatedAt ?? .distantPast
            let right = rhs.updatedAt ?? .distantPast
            if left == right { return lhs.displayTitle < rhs.displayTitle }
            return left > right
        case .title:
            return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
        }
    }
}

/// User-facing settings. Simple keys live in UserDefaults and are read
/// directly wherever needed; views bind with @AppStorage(AppSettings.Keys.*).
enum AppSettings {
    enum Keys {
        static let devecoPath = "devecoExecutablePath"
        static let devecoPathDetected = "devecoExecutablePathDetected"
        static let nodePath = "nodeExecutablePath"
        static let nodePathDetected = "nodeExecutablePathDetected"
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
        static let notifyOnlyWhenBackground = "notifyOnlyWhenBackground"
        static let savePromptHistory = "savePromptHistory"
        static let promptHistory = "promptHistory"
        static let sessionModels = "sessionModels"
        static let sessionVariants = "sessionVariants"
        static let sessionDrafts = "sessionDrafts"
        static let sessionSort = "sessionSortOrder"
        static let sidebarHidden = "sidebarHidden"
        static let settingsVersion = "settingsVersion"
        static let pinnedSessionIDs = "pinnedSessionIDs"
        static let clientAutoTitles = "clientAutoTitles"
        static let manuallyRenamedSessionIDs = "manuallyRenamedSessionIDs"
        static let recentModels = "recentModelChoices"
        static let appLanguage = "appLanguage"
        static let appAppearance = "appAppearance"
        static let savedPermissionRules = "savedPermissionRules"
    }

    static func registerDefaults() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.autoStartServer: true,
            Keys.basePort: 4096,
            Keys.quitBehavior: QuitBehavior.stopServer.rawValue,
            Keys.sendOnEnter: true,
            Keys.chatFontSize: 14.0,
            Keys.autoScroll: true,
            Keys.expandThinking: false,
            Keys.defaultSessionModel: "",
            Keys.devecoPath: "",
            Keys.notifyOnComplete: false,
            Keys.playSoundOnComplete: false,
            Keys.notifyOnlyWhenBackground: true,
            Keys.savePromptHistory: true,
            Keys.appAppearance: AppAppearance.dark.rawValue,
            Keys.sessionSort: SessionSortOrder.recent.rawValue,
            Keys.sidebarHidden: false,
        ])
        // One-shot migrations, gated by a single version marker so new rules
        // append instead of stacking one-off flag keys. v2 aligns the default
        // transcript body with Codex's 14px text while preserving larger
        // explicit user choices.
        if defaults.integer(forKey: Keys.settingsVersion) < 1 {
            if let stored = defaults.object(forKey: Keys.chatFontSize) as? Double,
               stored <= 16.0 {
                defaults.set(14.0, forKey: Keys.chatFontSize)
            }
            defaults.set(1, forKey: Keys.settingsVersion)
        }
        if defaults.integer(forKey: Keys.settingsVersion) < 2 {
            if defaults.double(forKey: Keys.chatFontSize) == 15.0 {
                defaults.set(14.0, forKey: Keys.chatFontSize)
            }
            defaults.set(2, forKey: Keys.settingsVersion)
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

    static var notifyOnlyWhenBackground: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Keys.notifyOnlyWhenBackground) != nil else { return true }
            return UserDefaults.standard.bool(forKey: Keys.notifyOnlyWhenBackground)
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.notifyOnlyWhenBackground) }
    }

    static var savePromptHistory: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Keys.savePromptHistory) != nil else { return true }
            return UserDefaults.standard.bool(forKey: Keys.savePromptHistory)
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.savePromptHistory) }
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
            UserDefaults.standard.removeObject(forKey: "AppleLocale")
        } else {
            // LaunchServices reads AppleLanguages at process launch, before
            // SwiftUI's init runs. Writing the same array again here makes
            // a language change take effect on the next restart without
            // requiring the user to launch the app twice.
            let current = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
            let currentLocale = UserDefaults.standard.string(forKey: "AppleLocale")
            let desiredLocale = language == "en" ? "en_CN" : "zh_CN"
            if current != [language] {
                UserDefaults.standard.set([language], forKey: "AppleLanguages")
                // AppleLocale must be a plain string. Writing an array here
                // makes macOS report "未能读取数据，因为它的格式不正确" on
                // launch when it reads the per-app override.
                UserDefaults.standard.set(language == "en" ? "en_CN" : "zh_CN", forKey: "AppleLocale")
            } else if currentLocale != desiredLocale {
                // Repair a locale written with the wrong type by an older
                // build (an array instead of a string).
                UserDefaults.standard.set(desiredLocale, forKey: "AppleLocale")
            }
        }
    }

    /// Codex-like dark canvas by default; users can still follow the system.
    static var appAppearance: AppAppearance {
        get { AppAppearance(rawValue: UserDefaults.standard.string(forKey: Keys.appAppearance) ?? "") ?? .dark }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.appAppearance) }
    }

    static func applyAppearanceOverride() {
        guard NSApp != nil else { return }
        switch appAppearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
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

    /// Per-session draft text, keyed by session id. Persisted so quitting the
    /// app never silently discards something the user was typing.
    static var sessionDrafts: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Keys.sessionDrafts) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.sessionDrafts) }
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

    /// Titles derived from the first prompt. The server may rename sessions
    /// from model output; keep these prompt titles authoritative until the
    /// user explicitly renames the session themselves.
    static var clientAutoTitles: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Keys.clientAutoTitles) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.clientAutoTitles) }
    }

    static var manuallyRenamedSessionIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: Keys.manuallyRenamedSessionIDs) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.manuallyRenamedSessionIDs) }
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
