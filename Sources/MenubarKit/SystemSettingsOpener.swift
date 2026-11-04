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
// 票 19 修票底双实例竞态：重启改为「先退后拉」——本进程先落一个独立存活的 shell 监视进程
//（轮询本进程 PID 消失后才 `open -n` 强拉新实例），再干净退出。旧实例退净在前，新实例拉起在后。
// 拉起监视进程失败时留在当前实例（避免应用无窗口可回地消失）。

public enum SelfRelauncher {
    /// 重拉起当前应用并干净退出。顺序：spawnWatcher（独立于本进程存活）→ terminate。
    /// spawnWatcher 抛错 = 监视进程落空，留在当前实例不自杀。
    public static func perform(spawnWatcher: (Int32, String) throws -> Void = SelfRelauncher.spawnRestartWatcher,
                               terminate: () -> Void = { NSApp.terminate(nil) }) {
        let bundleURL = Bundle.main.bundleURL
        let selfPID = ProcessInfo.processInfo.processIdentifier
        do {
            try spawnWatcher(selfPID, bundleURL.path)
        } catch {
            return
        }
        terminate()
    }

    /// 重启监视进程参数：`/bin/sh -c 'while kill -0 <pid> 2>/dev/null; do sleep 0.1; done;
    ///   /usr/bin/open -n <bundle 路径>'`——旧进程 PID 消失后才拉起，保证先退后拉。
    public static func restartWatcherArguments(pid: Int32, bundlePath: String) -> [String] {
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; /usr/bin/open -n \(bundlePath)"
        return ["-c", script]
    }

    /// 落一个独立于本进程存活的 shell 监视进程（detach 后本进程退出不影响它继续轮询）。
    /// 注意：绝不能 waitUntilExit——脚本要等本进程退出才结束，等待即死锁。
    public static func spawnRestartWatcher(_ pid: Int32, bundlePath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = restartWatcherArguments(pid: pid, bundlePath: bundlePath)
        try process.run()  // run() 返回即进程已 spawn；本进程随后 terminate，监视进程继续轮询
    }
}
