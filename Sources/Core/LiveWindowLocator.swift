import CoreGraphics
import Foundation

// LiveWindowLocator.swift — 实况窗口定位：屏归属 + Space + 屏内比例几何（spec §7.2）。
// 快照组装、恢复实况收集、VerifyCLI 共用这一口径（GLOSSARY「屏归属」）。
// 纯函数：不碰 SLS、不读 AX，Space 数据由调用方查好传入。
// 屏归属：
//   - 以窗口所属 Space 的屏为准：非可见 Space 后台窗的 frame 是过期值，按 frame 会归错屏
//     （11-03 实测：内置屏后台窗被记到中屏，restore 据此移错）
//   - 无 Space 归属（或其屏不在当前拓扑）：frame 交集面积最大者；完全在屏外：中心最近者
//   - 归属屏无稳定 UUID 或尺寸为 0：丢弃该窗（无从记录/比对）
// 比例几何：归属屏整块 bounds 上归一并夹 [0,1]（快照值是夹过的，比对两侧须同口径）。

/// 定位后的实况窗口
public struct LocatedWindow: Equatable, Sendable {
    public let sample: CGWindowSample
    /// 归属屏
    public let display: Displays.Info
    /// 所属 Space；SLS 无归属（粘性/辅助窗）或 Space 数据不可用时为 nil
    public let space: SpaceEntry?
    /// 归属屏整块 bounds 上的归一比例坐标（spec §7.2）
    public let x: Double, y: Double, w: Double, h: Double
}

public enum LiveWindowLocator {
    public static func locate(samples: [CGWindowSample], displays: [Displays.Info],
                              spaceIDByWindow: [UInt32: Int64],
                              spaceEntries: [SpaceEntry]) -> [LocatedWindow] {
        let spaceByID = Dictionary(spaceEntries.map { ($0.spaceID, $0) }, uniquingKeysWith: { a, _ in a })
        return samples.compactMap { sample in
            let space = spaceIDByWindow[sample.windowID].flatMap { spaceByID[$0] }
            guard let display = space.flatMap({ s in displays.first(where: { $0.uuid == s.displayUUID }) })
                ?? largestIntersection(sample.bounds, in: displays)
                ?? nearestCenter(sample.bounds, in: displays) else { return nil }
            let b = display.bounds
            guard let uuid = display.uuid, !uuid.isEmpty, b.width > 0, b.height > 0 else { return nil }
            func clamp01(_ v: CGFloat) -> Double { min(max(Double(v), 0), 1) }
            return LocatedWindow(
                sample: sample, display: display, space: space,
                x: clamp01((sample.bounds.minX - b.minX) / b.width),
                y: clamp01((sample.bounds.minY - b.minY) / b.height),
                w: clamp01(sample.bounds.width / b.width),
                h: clamp01(sample.bounds.height / b.height))
        }
    }

    /// bounds 交集面积最大者（displays 已按左→右排序，同积取先者）
    private static func largestIntersection(_ bounds: CGRect, in displays: [Displays.Info]) -> Displays.Info? {
        var best: (info: Displays.Info, area: Double)?
        for info in displays {
            let inter = info.bounds.intersection(bounds)
            guard !inter.isNull, inter.width > 0, inter.height > 0 else { continue }
            let area = Double(inter.width * inter.height)
            if best == nil || area > best!.area { best = (info, area) }
        }
        return best?.info
    }

    /// 窗口中心距屏中心最近者
    private static func nearestCenter(_ bounds: CGRect, in displays: [Displays.Info]) -> Displays.Info? {
        displays.min {
            hypot($0.bounds.midX - bounds.midX, $0.bounds.midY - bounds.midY)
                < hypot($1.bounds.midX - bounds.midX, $1.bounds.midY - bounds.midY)
        }
    }
}
