import Foundation

// LiveWindowSet.swift — 实况窗口集合口径（display-presets 票 11；诊断 acceptance4 R1）。
// 快照组装（SnapshotComposer）、恢复实况收集（RestoreEngine.collectLiveWindows）、VerifyCLI 枚举
// 共用这一份判定，三处不得另写。纯函数：SLS/AX 读经调用方注入的闭包，本文件不碰私有 API。
// 口径：
//   - 无 Space 归属（SLS 0 个 Space：TextInputUI、各 app 500×500 隐藏辅助窗等）与多 Space 粘性窗
//     （SpaceAdapter.spaceIDsByWindowID 已不入表）不入集合；Space 数据整体不可用（nil）时不按归属排除
//     （降级：frame 兜底定屏）
//   - ordered out（SLSWindowIsOrderedIn == false）：隐藏辅助窗与最小化窗都是（实测；在其他 Space 的真窗
//     ordered in）。经 AX 判 minimized：最小化 → 保留并记 minimized（L4）；所属应用被隐藏 → 按普通窗保留；
//     否则排除。排列数据不可用（nil）时不按排列排除，minimized 退回「不在屏才探」
//   - AX 只探需判定的窗，且整批一次交给调用方（按 pid 批量读，不得逐窗全量遍历）

/// 实况窗口集合的一员
public struct LiveWindowMember: Equatable, Sendable {
    /// 屏归属 + Space + 比例几何（Core.LiveWindowLocator）
    public let window: LocatedWindow
    public let minimized: Bool
}

public enum LiveWindowSet {
    /// - spaceIDByWindow: SpaceProviding.spaceIDsByWindowID 读数；nil = Space 数据整体不可用
    /// - orderedOut: 给定候选中 ordered out 者（SpaceProviding.orderedOutWindowIDs）；返回 nil = 排列数据不可用
    /// - minimized: 批量 AX 探测，返回其中最小化者（无需探测时不调用）
    public static func collect(samples: [CGWindowSample], displays: [Displays.Info],
                               spaceIDByWindow: [UInt32: Int64]?, spaceEntries: [SpaceEntry],
                               orderedOut: ([UInt32]) -> Set<UInt32>?,
                               minimized: ([CGWindowSample]) -> Set<UInt32>) -> [LiveWindowMember] {
        let located = LiveWindowLocator.locate(samples: samples, displays: displays,
                                               spaceIDByWindow: spaceIDByWindow ?? [:], spaceEntries: spaceEntries)
        let candidates = spaceIDByWindow.map { byWindow in
            located.filter { byWindow[$0.sample.windowID] != nil }
        } ?? located
        let out = orderedOut(candidates.map(\.sample.windowID))
        let probeTargets = candidates.filter { out?.contains($0.sample.windowID) ?? !$0.sample.isOnscreen }
        let minimizedIDs = probeTargets.isEmpty ? [] : minimized(probeTargets.map(\.sample))
        return candidates.compactMap { lw in
            let wid = lw.sample.windowID
            let isMinimized = minimizedIDs.contains(wid)
            if out?.contains(wid) == true, !isMinimized, !lw.sample.appHidden { return nil }
            return LiveWindowMember(window: lw, minimized: isMinimized)
        }
    }
}
