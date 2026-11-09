import AppKit
import CoreGraphics
import Foundation

// WindowSampling.swift — CG 窗口采样（spec §7.5）。一次性拍快照（SnapshotComposer）、恢复引擎实况收集、
// VerifyCLI 实时枚举共用这一份（verify 要能对引擎产出的快照做同口径枚举比对）。
// 采样本身零 AX（AX 只经 WindowAXProbing 按需另探）：本文件不调用任何 AX API，采样仅读
// CGWindowListCopyWindowInfo(.optionAll)（kCGWindowName 随调用免费返回）；
// AppKit 只用于 NSRunningApplication 的 bundleID 兜底与「所属应用被隐藏」（isHidden，每次采样读一次）。
// 候选过滤口径：
//   layer == 0、windowID ≠ 0、边长 ≥ 40px（辅助窗排除，05 spike：cmuxterm 24×24 不入快照）、
//   bundleID 取 CG 字典键、缺了再 NSRunningApplication(pid) 兜底、空 bundleID 排除。
// 采样只做廉价过滤；幽灵窗（无 Space / ordered out）的排除归 Core.LiveWindowSet（需 SLS/AX）。

/// 单个候选窗口的廉价采样（全部来自一次 CGWindowListCopyWindowInfo，无 AX）
public struct CGWindowSample: Equatable, Sendable {
    public let windowID: UInt32
    public let pid: Int32
    public let bundleID: String
    /// kCGWindowName；屏幕录制权限缺失时为 nil
    public let title: String?
    /// 全局坐标 bounds（kCGWindowBounds）
    public let bounds: CGRect
    /// kCGWindowIsOnscreen：最小化/在其他 Space 的窗口为 false（该键缺省 = false）
    public let isOnscreen: Bool
    /// 所属应用被隐藏（⌘H，NSRunningApplication.isHidden）：其窗可能 ordered out，按普通窗保留
    public let appHidden: Bool

    public init(windowID: UInt32, pid: Int32, bundleID: String, title: String?,
                bounds: CGRect, isOnscreen: Bool, appHidden: Bool = false) {
        self.windowID = windowID; self.pid = pid; self.bundleID = bundleID
        self.title = title; self.bounds = bounds; self.isOnscreen = isOnscreen
        self.appHidden = appHidden
    }
}

/// 窗口采样源接缝：默认 CGWindowList 实现，测试注入 fake（票面「注入 fake 的单元测试」）。
/// 实现约定：只做 CG 读取，禁止 AX 调用（采样零 AX 的结构性约束；AX 按需另探）。
public protocol WindowEnumerating: Sendable {
    func sample() -> [CGWindowSample]
}

/// 默认采样实现：CGWindowListCopyWindowInfo(.optionAll) → 候选过滤（口径见文件头）
public struct CGWindowListEnumerator: WindowEnumerating {
    /// 辅助窗排除边长（px，05 spike 实测口径）
    public static let minWindowEdge: Double = 40

    public init() {}

    // CGWindowList 字典里 bundle ID 的键名（SDK 未导出；实测返回字典含此键，macOS 15）
    private static let bundleIDKey = "kCGWindowBundleID"

    public func sample() -> [CGWindowSample] {
        let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let hidden = Set(NSWorkspace.shared.runningApplications.filter(\.isHidden).map(\.processIdentifier))
        return Self.sample(from: raw, hiddenPIDs: hidden)
    }

    /// sample() 的纯函数核心（raw = CGWindowListCopyWindowInfo 字典数组；hiddenPIDs = 被隐藏应用的 pid）
    static func sample(from raw: [[String: Any]], hiddenPIDs: Set<Int32>) -> [CGWindowSample] {
        var out: [CGWindowSample] = []
        for dict in raw {
            let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard layer == 0 else { continue }
            guard let wid = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value, wid != 0 else { continue }
            guard let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary else { continue }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &bounds),
                  bounds.width >= Self.minWindowEdge,
                  bounds.height >= Self.minWindowEdge else { continue }
            let pid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            var bundleID = dict[Self.bundleIDKey as String] as? String ?? ""
            if bundleID.isEmpty, let app = NSRunningApplication(processIdentifier: pid) {
                bundleID = app.bundleIdentifier ?? ""
            }
            guard !bundleID.isEmpty else { continue }
            let title = dict[kCGWindowName as String] as? String
            // 该键只在窗真在屏上时出现（实测 376 个 layer-0 窗只有 8 个带键，全为 true）：缺键 = 不在屏
            let onscreen = (dict[kCGWindowIsOnscreen as String] as? Bool) ?? false
            out.append(CGWindowSample(windowID: wid, pid: pid, bundleID: bundleID,
                                      title: title, bounds: bounds, isOnscreen: onscreen,
                                      appHidden: hiddenPIDs.contains(pid)))
        }
        return out
    }
}
