import Foundation

// UserDesktopMapping.swift — 普通窗目标 Space 映射（display-presets 票 12 引入，票 15 下沉 Core）。
// 恢复落位（RestoreEngine L2/L4）与 verify 比对（VerifyComparer）共用这一份，禁止出现第二份映射实现。

public enum UserDesktopMapping {
    /// 普通窗目标 Space（spec §5.3/§6.7）。只在同屏用户桌面中选，
    /// 全屏 Space 永不作为普通窗目标（全屏 Space 与桌面可被用户重排，绝对 index 会错位，验收4 实测）：
    ///   快照窗所在 Space 是用户桌面 → 取它在快照同屏用户桌面中的序号 k → 实况同屏第 k 个用户桌面；
    ///   实况用户桌面不足 → 就近并入最后一个（mergedFrom = 快照 index，不补建）；
    ///   快照无该 Space 记录（或记为全屏，旧预设数据）→ 按 index 在实况用户桌面中定位，不命中就近并入；
    ///   目标屏无用户桌面 → nil。现状多出（A13）无需特判：第 k 个照常命中。
    public static func targetSpace(displayUUID: String, snapshotIndex: Int, snapshotSpaces: [SnapshotSpace],
                                   entries: [SpaceEntry]) -> (entry: SpaceEntry, mergedFrom: Int?)? {
        let liveDesktops = entries
            .filter { $0.displayUUID == displayUUID && $0.kind == SpaceKind.user }
            .sorted { $0.index < $1.index }
        guard let last = liveDesktops.last else { return nil }
        let snapshotDesktops = snapshotSpaces
            .filter { $0.displayUUID == displayUUID && $0.kind == .user }
            .map(\.index).sorted()
        if let ordinal = snapshotDesktops.firstIndex(of: snapshotIndex) {
            return ordinal < liveDesktops.count ? (liveDesktops[ordinal], nil) : (last, snapshotIndex)
        }
        if let exact = liveDesktops.first(where: { $0.index == snapshotIndex }) {
            return (exact, nil)
        }
        let nearest = liveDesktops.min { abs($0.index - snapshotIndex) < abs($1.index - snapshotIndex) } ?? last
        return (nearest, snapshotIndex)
    }
}
