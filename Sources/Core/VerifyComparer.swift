import Foundation

// VerifyComparer.swift — verify 全量比对核心（票 14，spec §9.1）。
// 预期 SKIP 集推导与恢复管线共用同一份 Core.ConservativeMatcher（08 #1，禁止出现第二份匹配实现）。
// 判定口径与 RestoreEngine 管线的保守语义一致：
//   SKIP = 管线按保守语义「不动」的条目：未运行应用（§6.4a）/ 匹配不上不猜（§6.4c）/
//          快照 minimized 条目与实况最小化窗口（L4 归票 15）；
//          粘性窗 / 无归属辅助窗不入匹配集合，天然落在 SKIP 一侧（§5.3）。
//   PASS = 几何精确（1e-6 吸收浮点串化噪声）+ 屏幕归属 + Space 归属全比对通过；
//          Space 归属按恢复落位同一份映射（Core.UserDesktopMapping，同屏用户桌面序号）算期望 Space，
//          不按绝对 index 比（Space 重排后绝对 index 错位，display-presets 票 15）；
//          某维度数据缺失（如本进程无 SLS/AX 授权）→ 该维度「无法核验」（nil），不阻断不崩溃。

/// 单条快照条目的核验结论（verify 报告逐行数据源）
public struct VerifyEntryResult: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        /// 几何 + 屏幕归属 + Space 归属全比对通过
        case pass
        /// 比对失败，reasons ⊆ {geometry, display, space}
        case fail(reasons: [String])
        /// 预期跳过（保守匹配「不动」集合，spec §9.3 判定标准 3）
        case skip(reason: String)
    }

    public let snapshotIndex: Int
    public let verdict: Verdict
    /// 配对上的实况窗口 ID；未配对（SKIP）为 nil
    public let liveWindowID: UInt32?
    /// 屏幕归属比对结果；nil = 归属数据缺失，无法核验（不阻断）
    public let displayMatched: Bool?
    /// Space 归属（L2）比对结果；nil = 本进程无 SLS 授权等数据缺失，无法核验（不阻断）
    public let spaceMatched: Bool?
    /// 映射后的期望 Space index（恢复落位口径）；未配对 / 无 Space 数据 / 目标屏无用户桌面为 nil
    public let expectedSpaceIndex: Int?
    /// 比例几何最大分量差；未配对为 nil
    public let geometryDelta: Double?
    /// 经二级几何兜底配对（标题不一致）；未配对为 false
    public let viaGeometryFallback: Bool

    public init(snapshotIndex: Int, verdict: Verdict,
                liveWindowID: UInt32? = nil, displayMatched: Bool? = nil,
                spaceMatched: Bool? = nil, expectedSpaceIndex: Int? = nil, geometryDelta: Double? = nil,
                viaGeometryFallback: Bool = false) {
        self.snapshotIndex = snapshotIndex
        self.verdict = verdict
        self.liveWindowID = liveWindowID
        self.displayMatched = displayMatched
        self.spaceMatched = spaceMatched
        self.expectedSpaceIndex = expectedSpaceIndex
        self.geometryDelta = geometryDelta
        self.viaGeometryFallback = viaGeometryFallback
    }
}

public enum VerifyComparer {
    /// 几何相等容差：同分辨率同旋转下比例坐标应逐位相等，1e-6 吸收浮点串化噪声
    /// （VerifyCLI 雏形同值；spec §9.3 终验判定收紧为精确相等时只改这里）
    public static let geometryTolerance = 1e-6

    /// 全量比对：每条快照条目一个结论，顺序与 snapshot.windows 一致。
    /// displayUUIDByWindowID / spaceEntryByWindowID 缺项 = 该维度数据缺失 → 结果 nil（无法核验，不崩不阻断）。
    /// liveSpaces = 实况受管 Space 全量清单（期望 Space 映射用，与恢复引擎同一输入）。
    public static func compare(snapshot: Snapshot,
                               liveWindows: [LiveWindow],
                               displayUUIDByWindowID: [UInt32: String],
                               spaceEntryByWindowID: [UInt32: SpaceEntry],
                               liveSpaces: [SpaceEntry]) -> [VerifyEntryResult] {
        let outcome = ConservativeMatcher.match(snapshotWindows: snapshot.windows, liveWindows: liveWindows)
        let matchBySnapshot = Dictionary(uniqueKeysWithValues: outcome.matches.map { ($0.snapshotIndex, $0) })
        let liveBundleIDs = Set(liveWindows.map(\.bundleID))

        return snapshot.windows.enumerated().map { s, snap in
            guard let match = matchBySnapshot[s] else {
                // 预期 SKIP 推导（共享匹配器）：同应用在跑但键/几何均未配上 = unmatched；否则应用未运行 = app-not-running
                let reason = liveBundleIDs.contains(snap.bundleID) ? "unmatched" : "app-not-running"
                return VerifyEntryResult(snapshotIndex: s, verdict: .skip(reason: reason))
            }
            let live = liveWindows[match.liveIndex]
            let fallback = match.viaGeometryFallback
            // L4 归票 15（引擎计划同因跳过）：快照 minimized 条目 / 实况最小化窗口按保守「不动」核验为预期跳过
            if snap.minimized {
                return VerifyEntryResult(snapshotIndex: s, verdict: .skip(reason: "minimized-entry-L4"),
                                         liveWindowID: live.cgWindowID, viaGeometryFallback: fallback)
            }
            if live.minimized {
                return VerifyEntryResult(snapshotIndex: s, verdict: .skip(reason: "live-minimized"),
                                         liveWindowID: live.cgWindowID, viaGeometryFallback: fallback)
            }

            var reasons: [String] = []
            let delta = max(abs(snap.x - live.x), abs(snap.y - live.y),
                            abs(snap.w - live.w), abs(snap.h - live.h))
            if delta > geometryTolerance { reasons.append("geometry") }

            // 屏幕归属：快照 displayUUID ↔ 实况屏归属 UUID（LiveWindowLocator 口径）
            let displayMatched = displayUUIDByWindowID[live.cgWindowID].map { $0 == snap.displayUUID }
            if let matched = displayMatched, !matched { reasons.append("display") }

            // Space 归属（L2）：映射后的期望 Space ↔ 实况窗所在 Space（单归属，spec §5.1）。
            // 期望 Space 与恢复落位同一份映射；目标屏无用户桌面（恢复 L2 跳过）→ 不可能落对，判不符
            let expected = UserDesktopMapping.targetSpace(
                displayUUID: snap.displayUUID, snapshotIndex: snap.spaceIndex,
                snapshotSpaces: snapshot.spaces, entries: liveSpaces)?.entry
            let spaceMatched = spaceEntryByWindowID[live.cgWindowID].map { $0.spaceID == expected?.spaceID }
            if let matched = spaceMatched, !matched { reasons.append("space") }

            if reasons.isEmpty {
                return VerifyEntryResult(snapshotIndex: s, verdict: .pass, liveWindowID: live.cgWindowID,
                                         displayMatched: displayMatched, spaceMatched: spaceMatched,
                                         expectedSpaceIndex: expected?.index,
                                         geometryDelta: delta, viaGeometryFallback: fallback)
            }
            return VerifyEntryResult(snapshotIndex: s, verdict: .fail(reasons: reasons), liveWindowID: live.cgWindowID,
                                     displayMatched: displayMatched, spaceMatched: spaceMatched,
                                     expectedSpaceIndex: expected?.index, geometryDelta: delta, viaGeometryFallback: fallback)
        }
    }
}
