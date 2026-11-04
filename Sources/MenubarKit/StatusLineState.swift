// StatusLineState.swift — 菜单状态行三态（票 19，spec §8.2「状态行三种显示」）。
// 「三屏 · 快照就绪」／「三屏 · 无匹配快照」／「一屏（拔出）」——按当前显示器数与现势快照
// 匹配态动态判定：单屏即拔出态（单屏基线快照由自动快照照常维护，恢复入口对单屏无意义）；
// 多屏按现势快照（live-<拓扑键>）是否存在决定就绪措辞。屏数以中文数字呈现（spec 示例 一/三）。

public enum StatusLineState: Equatable {
    /// 多屏 · 有现势快照
    case snapshotReady(displayCount: Int)
    /// 多屏 · 无匹配快照
    case noMatchingSnapshot(displayCount: Int)
    /// 单屏（拔出）
    case pluggedOut

    /// 判定入口（菜单构建时调用）
    public static func state(displayCount: Int, hasMatchingLiveSnapshot: Bool) -> StatusLineState {
        if displayCount <= 1 { return .pluggedOut }
        return hasMatchingLiveSnapshot ? .snapshotReady(displayCount: displayCount)
                                       : .noMatchingSnapshot(displayCount: displayCount)
    }

    /// 菜单状态行标题（spec §8.2 逐字措辞）
    public var title: String {
        switch self {
        case .pluggedOut:
            return "一屏（拔出）"
        case .snapshotReady(let count):
            return "\(Self.chineseNumeral(count))屏 · 快照就绪"
        case .noMatchingSnapshot(let count):
            return "\(Self.chineseNumeral(count))屏 · 无匹配快照"
        }
    }

    /// 静态便捷入口（判定 + 标题一步）
    public static func title(displayCount: Int, hasMatchingLiveSnapshot: Bool) -> String {
        state(displayCount: displayCount, hasMatchingLiveSnapshot: hasMatchingLiveSnapshot).title
    }

    /// 屏数中文数字（一二三四五六七八九十；超出十以阿拉伯数字兜底——验收拓扑 ≤3 屏，纯防御）
    static func chineseNumeral(_ count: Int) -> String {
        let numerals = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        guard count >= 0, count < numerals.count else { return String(count) }
        return numerals[count]
    }
}
