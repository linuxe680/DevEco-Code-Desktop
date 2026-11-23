import Foundation
import ServiceManagement

/// macOS 11 没有 SMAppService；用 LaunchServices 的兼容 API 管理登录项。
enum LoginItemManager {
    /// macOS 12 and earlier require a bundled login helper in
    /// Contents/Library/LoginItems, which this app does not ship. Hide the
    /// toggle there instead of failing every time it is flipped.
    static var isSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        // SMLoginItemSetEnabled 是设置函数，无法查询状态；旧系统保守显示关闭。
        return false
    }

    static func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return
        }
        throw NSError(
            domain: "LoginItemManager",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: NSLocalizedString(
                "Launch at login requires macOS 13 or later.",
                comment: ""
            )]
        )
    }
}
