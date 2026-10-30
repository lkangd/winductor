import AppKit

// SystemSettingsOpener.swift — 系统设置面板深链（票 18，spec §8.3 的【打开系统设置】接线）。
// 面板标识为任务书指定：辅助功能 Privacy_Accessibility、屏幕与系统录音 Privacy_ScreenCapture。
// 重确认菜单状态行（§8.4「点击直达系统设置」）复用此处打开屏幕与系统录音面板。

public enum SystemSettingsOpener {
    /// 隐私与安全性 > 辅助功能
    public static let accessibilityPaneURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    /// 隐私与安全性 > 屏幕与系统录音
    public static let screenCapturePaneURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// 打开指定权限项对应的系统设置面板（默认 NSWorkspace 深链，等价 `open <url>`）
    public static func open(_ kind: PermissionMonitor.Kind) {
        switch kind {
        case .accessibility:
            NSWorkspace.shared.open(accessibilityPaneURL)
        case .screenCapture:
            NSWorkspace.shared.open(screenCapturePaneURL)
        }
    }
}

// SelfRelauncher.swift — 立即重启（票 18，spec §8.3「✓ 两项授权已齐备。请重启应用使授权生效。【立即重启】」）。
// 立即重启 = 干净退出自身 + `open` 自己（Bundle.main URL 重拉起）。授权生效需重启一次（spec §4.6，07 #8）。

public enum SelfRelauncher {
    /// 重拉起当前应用并干净退出。拉起失败时留在当前实例（避免应用无窗口可回地消失）。
    public static func perform(openNewInstance: (URL) throws -> Void = SelfRelauncher.openNewInstanceViaOpenCommand,
                               terminate: () -> Void = { NSApp.terminate(nil) }) {
        let bundleURL = Bundle.main.bundleURL
        do {
            try openNewInstance(bundleURL)
        } catch {
            return
        }
        terminate()
    }

    /// `/usr/bin/open -n`：强制新实例——不带 -n 时 LaunchServices 会把 open 解析为
    /// 「激活正在退出的旧实例」，重启变成自杀。
    public static func openNewInstanceViaOpenCommand(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", url.path]
        try process.run()
    }
}
