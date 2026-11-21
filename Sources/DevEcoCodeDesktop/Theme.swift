import SwiftUI

/// Semantic design tokens. Ad hoc `Color.x.opacity(y)` literals get swept to
/// these so banners/cards/strokes stay consistent across views.
enum Theme {
    /// Codex-like neutral surfaces. The transcript sits on the darkest canvas,
    /// while navigation and chrome step up one level for separation.
    static let canvas = adaptive(light: 0xFFFFFF, dark: 0x181818)
    static let sidebarFill = adaptive(light: 0xF9F9F9, dark: 0x1F1F1F)
    static let barFill = adaptive(light: 0xF4F4F4, dark: 0x242424)
    static let chromeFill = adaptive(light: 0xF7F7F7, dark: 0x222222)
    static let composerFill = adaptive(light: 0xFFFFFF, dark: 0x2B2B2B)
    static let windowChromeNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 36.0 / 255.0, green: 36.0 / 255.0, blue: 36.0 / 255.0, alpha: 1)
            : NSColor(srgbRed: 247.0 / 255.0, green: 247.0 / 255.0, blue: 247.0 / 255.0, alpha: 1)
    }

    // Banners
    static let bannerWarning = Color.orange.opacity(0.12)
    static let bannerInfo = Color.blue.opacity(0.10)
    static let bannerError = Color.red.opacity(0.08)
    // Cards & chips
    static let cardFill = Color.primary.opacity(0.045)
    static let chipFill = Color.primary.opacity(0.06)
    static let subtleFill = Color.primary.opacity(0.035)
    static let hoverFill = Color.primary.opacity(0.07)
    // Strokes
    static let stroke = Color.secondary.opacity(0.28)
    static let softStroke = Color.secondary.opacity(0.18)
    static let hairline = Color.secondary.opacity(0.12)
    // Use a neutral, low-saturation bubble; Codex keeps the transcript calm.
    static let userBubble = Color(red: 0.925, green: 0.925, blue: 0.925)
    static let userBubbleStroke = Color.primary.opacity(0.06)
    static let assistantBubble = Color(nsColor: .controlBackgroundColor)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        let lightColor = NSColor(srgbRed: CGFloat((light >> 16) & 0xFF) / 255,
                                 green: CGFloat((light >> 8) & 0xFF) / 255,
                                 blue: CGFloat(light & 0xFF) / 255,
                                 alpha: 1)
        let darkColor = NSColor(srgbRed: CGFloat((dark >> 16) & 0xFF) / 255,
                                green: CGFloat((dark >> 8) & 0xFF) / 255,
                                blue: CGFloat(dark & 0xFF) / 255,
                                alpha: 1)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? darkColor
                : lightColor
        })
    }

    static func toolTint(_ tool: String) -> Color {
        switch tool.lowercased() {
        case let name where name.contains("edit") || name.contains("write") || name.contains("patch"):
            return .orange
        case let name where name.contains("read"):
            return .blue
        case let name where name.contains("grep") || name.contains("search") || name.contains("glob"):
            return .purple
        case let name where name.contains("web"):
            return .teal
        case let name where name.contains("bash") || name.contains("shell") || name.contains("terminal"):
            return .green
        default:
            return .secondary
        }
    }

    static func toolSymbol(_ tool: String) -> String {
        switch tool.lowercased() {
        case let name where name.contains("edit") || name.contains("write") || name.contains("patch"):
            return "square.and.pencil"
        case let name where name.contains("read"):
            return "doc.text"
        case let name where name.contains("grep") || name.contains("search") || name.contains("glob"):
            return "magnifyingglass"
        case let name where name.contains("list") || name.contains("find"):
            return "folder"
        case let name where name.contains("web") || name.contains("fetch"):
            return "globe"
        case let name where name.contains("bash") || name.contains("shell") || name.contains("terminal"):
            return "terminal"
        default:
            return "wrench.and.screwdriver"
        }
    }

    /// Localized, human-readable tool names for transcript cards and activity
    /// labels. Unknown tools keep a readable title instead of a raw id.
    static func toolName(_ tool: String?) -> String {
        let raw = (tool ?? "tool")
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")

        let key: String
        switch raw {
        case "read": key = "Read"
        case "write": key = "Write"
        case "edit": key = "Edit"
        case "patch", "apply-patch": key = "Patch"
        case "bash", "shell": key = "Bash"
        case "grep": key = "Grep"
        case "glob": key = "Glob"
        case "list": key = "List"
        case "webfetch", "web-fetch": key = "Web Fetch"
        case "websearch", "web-search": key = "Web Search"
        case "codesearch", "code-search": key = "Code Search"
        case "read-image", "image": key = "Read Image"
        case "task": key = "Task"
        case "question": key = "Question"
        case "todoread", "todo-read": key = "Todo Read"
        case "todowrite", "todo-write": key = "Todo Write"
        case "memory-read": key = "Memory Read"
        case "memory-search": key = "Memory Search"
        case "memory-write": key = "Memory Write"
        case "skill": key = "Skill"
        default:
            if raw.contains("memory") && raw.contains("search") {
                key = "Memory Search"
            } else if raw.contains("memory") && raw.contains("write") {
                key = "Memory Write"
            } else if raw.contains("memory") && raw.contains("read") {
                key = "Memory Read"
            } else if raw.contains("web") && raw.contains("search") {
                key = "Web Search"
            } else if raw.contains("web") && (raw.contains("fetch") || raw.contains("read")) {
                key = "Web Fetch"
            } else if raw.contains("todo") && raw.contains("write") {
                key = "Todo Write"
            } else if raw.contains("todo") && raw.contains("read") {
                key = "Todo Read"
            } else if raw == "tool" || raw.isEmpty {
                key = "Tool"
            } else {
                let readable = raw.replacingOccurrences(of: "-", with: " ")
                return readable.prefix(1).uppercased() + readable.dropFirst()
            }
        }
        return NSLocalizedString(key, comment: "tool name")
    }
}

/// One source of truth for chat type scaling. The user setting drives prose,
/// metadata, code, and tool output instead of each view hard-coding a size.
enum ChatTypography {
    static let minFontSize = 13.0
    static let maxFontSize = 30.0

    static func body(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, minFontSize), maxFontSize))
    }

    static func meta(_ value: Double) -> CGFloat {
        max(12.5, body(value) - 2)
    }

    static func micro(_ value: Double) -> CGFloat {
        max(12, body(value) - 3)
    }

    static func code(_ value: Double) -> CGFloat {
        max(13, body(value) - 1)
    }

    static func heading(_ value: Double, level: Int) -> CGFloat {
        let bump: CGFloat = level <= 1 ? 5 : (level == 2 ? 3 : 1)
        return body(value) + bump
    }

    static func lineSpacing(_ value: Double) -> CGFloat {
        max(2, body(value) * 0.28)
    }
}
