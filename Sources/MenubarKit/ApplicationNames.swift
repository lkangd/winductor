import AppKit

// ApplicationNames.swift — bundleID → 人读应用名（预设详情「终端（2 个窗口）」/「全屏 · Safari」，票 08）。
// 查找顺序：正在运行的实例 localizedName → LaunchServices 定位 .app 后取 Finder 显示名（去 .app）。
// 解析不到返回 nil，调用方（PresetDetail）回退 bundleID。结果缓存：应用名在进程生命周期内视为不变。

public enum ApplicationNames {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    public static func localizedName(bundleID: String) -> String? {
        lock.lock()
        if let cached = cache[bundleID] { lock.unlock(); return cached }
        lock.unlock()
        let name = resolve(bundleID)
        lock.lock()
        cache[bundleID] = name
        lock.unlock()
        return name
    }

    private static func resolve(_ bundleID: String) -> String? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.localizedName {
            return running
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let display = FileManager.default.displayName(atPath: url.path)
        return display.hasSuffix(".app") ? String(display.dropLast(4)) : display
    }
}
