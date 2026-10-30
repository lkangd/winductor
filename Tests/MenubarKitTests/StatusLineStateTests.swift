import XCTest
@testable import MenubarKit

// 票 19：状态行三态判定（spec §8.2「状态行三种显示」）。
// 接缝：StatusLineState 的公开判定入口——按当前显示器数 + 现势快照匹配态产出菜单状态行标题。
// 独立事实来源：spec §8.2 逐字引文（测试自带字面量，不用实现常量自证）。
final class StatusLineStateTests: XCTestCase {
    /// 单屏 = 拔出态（与快照匹配无关）：「一屏（拔出）」
    func testSingleDisplayShowsPluggedOutRegardlessOfSnapshot() {
        XCTAssertEqual(StatusLineState.title(displayCount: 1, hasMatchingLiveSnapshot: true), "一屏（拔出）")
        XCTAssertEqual(StatusLineState.title(displayCount: 1, hasMatchingLiveSnapshot: false), "一屏（拔出）")
    }

    /// 多屏且有现势快照：spec §8.2 验收拓扑原文「三屏 · 快照就绪」
    func testThreeDisplayReadyMatchesSpecVerbatim() {
        XCTAssertEqual(StatusLineState.title(displayCount: 3, hasMatchingLiveSnapshot: true), "三屏 · 快照就绪")
    }

    /// 多屏但无匹配快照：spec §8.2 验收拓扑原文「三屏 · 无匹配快照」
    func testThreeDisplayWithoutSnapshotMatchesSpecVerbatim() {
        XCTAssertEqual(StatusLineState.title(displayCount: 3, hasMatchingLiveSnapshot: false), "三屏 · 无匹配快照")
    }

    /// 其他屏数按同构措辞动态产出（中文数字）
    func testTwoDisplaysProduceChineseNumeral() {
        XCTAssertEqual(StatusLineState.title(displayCount: 2, hasMatchingLiveSnapshot: true), "二屏 · 快照就绪")
        XCTAssertEqual(StatusLineState.title(displayCount: 4, hasMatchingLiveSnapshot: false), "四屏 · 无匹配快照")
    }
}
