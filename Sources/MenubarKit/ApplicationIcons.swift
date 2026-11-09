import AppKit
import UniformTypeIdentifiers

// ApplicationIcons.swift — bundleID → 应用图标（拓扑页预设详情的应用行 16pt 图标，ui-refactor 票 04 spec §5.4）。
// LaunchServices 定位 .app 后取 Finder 图标；本机找不到该应用时用通用应用图标。结果缓存（进程生命周期内视为不变），
// 只在主线程（SwiftUI 视图）调用。

enum ApplicationIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(bundleID: String) -> NSImage {
        if let cached = cache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .application)
        cache[bundleID] = icon
        return icon
    }
}
