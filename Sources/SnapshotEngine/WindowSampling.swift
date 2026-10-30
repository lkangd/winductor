import AppKit
import Core
import CoreGraphics
import Foundation

// WindowSampling.swift — 轮询环采样与差分指纹（spec §7.5）。
// 本文件是「轮询环零 AX」的结构性保证：只依赖 CoreGraphics/Foundation，
// 采样仅读 CGWindowListCopyWindowInfo(.optionAll)（kCGWindowName 随调用免费返回）。
// 候选过滤口径与 VerifyCLI 完全一致（verify 要能对引擎产出的快照做同口径枚举比对）：
//   layer == 0、windowID ≠ 0、边长 ≥ 40px（辅助窗排除，05 spike：cmuxterm 24×24 不入快照）、
//   bundleID 取 CG 字典键、缺了再 NSRunningApplication(pid) 兜底、空 bundleID 排除。

/// 单个候选窗口的廉价采样（全部来自一次 CGWindowListCopyWindowInfo，无 AX）
public struct CGWindowSample: Equatable, Sendable {
    public let windowID: UInt32
    public let pid: Int32
    public let bundleID: String
    /// kCGWindowName；屏幕录制权限缺失时为 nil
    public let title: String?
    /// 全局坐标 bounds（kCGWindowBounds）
    public let bounds: CGRect
    /// kCGWindowIsOnscreen：最小化/在其他 Space 的窗口为 false
    public let isOnscreen: Bool

    public init(windowID: UInt32, pid: Int32, bundleID: String, title: String?,
                bounds: CGRect, isOnscreen: Bool) {
        self.windowID = windowID; self.pid = pid; self.bundleID = bundleID
        self.title = title; self.bounds = bounds; self.isOnscreen = isOnscreen
    }
}

/// 窗口采样源接缝：默认 CGWindowList 实现，测试注入 fake（票面「注入 fake 的单元测试」）。
/// 实现约定：只做 CG 读取，禁止 AX 调用（轮询环零 AX 的结构性约束）。
public protocol WindowEnumerating: Sendable {
    func sample() -> [CGWindowSample]
}

/// 默认采样实现：CGWindowListCopyWindowInfo(.optionAll) → 候选过滤（口径见文件头）
public struct CGWindowListEnumerator: WindowEnumerating {
    public init() {}

    // CGWindowList 字典里 bundle ID 的键名（SDK 未导出；与 VerifyCLI 同口径）
    private static let bundleIDKey = "kCGWindowBundleID"

    public func sample() -> [CGWindowSample] {
        let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var out: [CGWindowSample] = []
        for dict in raw {
            let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard layer == 0 else { continue }
            guard let wid = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value, wid != 0 else { continue }
            guard let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary else { continue }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &bounds),
                  bounds.width >= SnapshotEngineConstants.minWindowEdge,
                  bounds.height >= SnapshotEngineConstants.minWindowEdge else { continue }
            let pid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            var bundleID = dict[Self.bundleIDKey as String] as? String ?? ""
            if bundleID.isEmpty, let app = NSRunningApplication(processIdentifier: pid) {
                bundleID = app.bundleIdentifier ?? ""
            }
            guard !bundleID.isEmpty else { continue }
            let title = dict[kCGWindowName as String] as? String
            let onscreen = (dict[kCGWindowIsOnscreen as String] as? Bool) ?? true
            out.append(CGWindowSample(windowID: wid, pid: pid, bundleID: bundleID,
                                      title: title, bounds: bounds, isOnscreen: onscreen))
        }
        return out
    }
}

/// 差分指纹 = 拓扑（UUID + bounds + 旋转）+ 候选窗口集合（按 windowID 排序）。
/// 指纹相等 ⇔ 无变化不写盘（spec §7.5）；拓扑入指纹使屏幕事件（分辨率/插拔）必被检出。
public struct WindowFingerprint: Equatable, Sendable {
    struct DisplayMark: Equatable, Sendable {
        let uuid: String
        let bounds: CGRect
        let orientation: Int
    }
    let topology: [DisplayMark]
    let windows: [CGWindowSample]

    public init(displays: [Displays.Info], windows: [CGWindowSample]) {
        self.topology = displays.map {
            DisplayMark(uuid: $0.uuid ?? "", bounds: $0.bounds, orientation: Displays.rotation(for: $0.id))
        }
        self.windows = windows.sorted { $0.windowID < $1.windowID }
    }
}
