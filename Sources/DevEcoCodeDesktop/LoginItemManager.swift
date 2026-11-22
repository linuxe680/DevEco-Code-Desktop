import Foundation
import ServiceManagement

/// macOS 11 没有 SMAppService；用 LaunchServices 的兼容 API 管理登录项。
enum LoginItemManager {
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
        guard SMLoginItemSetEnabled("com.local.deveco-codesktop.loginhelper" as CFString, enabled) else {
            throw NSError(
                domain: "LoginItemManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Could not change login item.", comment: "")]
            )
        }
    }
}
