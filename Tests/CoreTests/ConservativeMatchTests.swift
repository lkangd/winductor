import XCTest
@testable import Core

// ConservativeMatchTests — 保守匹配核心验收（spec §7.1）。
// 接缝：ConservativeMatcher.match / siblingOrder（app 与 verify 共用同一份）。
final class ConservativeMatchTests: XCTestCase {
    private func live(_ bundle: String, _ title: String, x: Double, y: Double,
                      wid: UInt32 = 0, minimized: Bool = false) -> LiveWindow {
        LiveWindow(cgWindowID: wid, bundleID: bundle, title: title,
                   x: x, y: y, w: 0.5, h: 0.5, minimized: minimized)
    }
    private func snapWin(_ bundle: String, _ title: String, sibling: Int,
                         x: Double, y: Double, minimized: Bool = false) -> SnapshotWindow {
        SnapshotWindow(bundleID: bundle, title: title, siblingIndex: sibling,
                       displayUUID: "U", spaceIndex: 1,
                       x: x, y: y, w: 0.5, h: 0.5, minimized: minimized)
    }

    // MARK: 兄弟序（先 y 后 x）

    /// 同应用同标题多窗口按「先 y 后 x」确定性排序（spec §7.1）
    func testSiblingOrderIsYThenX() {
        let windows = [
            live("app", "same", x: 0.5, y: 0.9),
            live("app", "same", x: 0.8, y: 0.1),
            live("app", "same", x: 0.2, y: 0.1),
        ]
        let ordered = ConservativeMatcher.siblingOrder(windows)
        XCTAssertEqual(ordered.map(\.x), [0.2, 0.8, 0.5], "y 相同按 x 升序，再按 y 升序")
    }

    /// 匹配键对位：快照 siblingIndex 0/1/2 对到存活侧 y-then-x 序的第 0/1/2 个
    func testPrimaryMatchUsesSiblingIndex() {
        let snapshots = [
            snapWin("app", "same", sibling: 0, x: 0.1, y: 0.1),
            snapWin("app", "same", sibling: 1, x: 0.8, y: 0.1),
            snapWin("app", "same", sibling: 2, x: 0.5, y: 0.9),
        ]
        let lives = [
            live("app", "same", x: 0.5, y: 0.9, wid: 1),
            live("app", "same", x: 0.2, y: 0.1, wid: 2),
            live("app", "same", x: 0.8, y: 0.1, wid: 3),
        ]
        let outcome = ConservativeMatcher.match(snapshotWindows: snapshots, liveWindows: lives)
        XCTAssertNil(outcome.unmatchedSnapshotIndexes.first)
        XCTAssertEqual(outcome.matches.map { lives[$0.liveIndex].cgWindowID }, [2, 3, 1],
                       "存活侧按 (y,x) 排序后序号 0/1/2 应分别对位 wid 2/3/1")
        XCTAssertEqual(outcome.matches.map(\.viaGeometryFallback), [false, false, false])
    }

    // MARK: 几何兜底

    /// 标题失配 → 同应用未占用窗口按比例几何最近邻（距离 ≤ 0.15）
    func testGeometryFallbackWithinThreshold() {
        let snapshots = [snapWin("app", "旧标题", sibling: 0, x: 0.2, y: 0.2)]
        let lives = [live("app", "新标题(切了tab)", x: 0.25, y: 0.2, wid: 7)]  // 距离 0.05
        let outcome = ConservativeMatcher.match(snapshotWindows: snapshots, liveWindows: lives)
        XCTAssertEqual(outcome.matches.count, 1)
        XCTAssertTrue(outcome.matches[0].viaGeometryFallback)
        XCTAssertEqual(lives[outcome.matches[0].liveIndex].cgWindowID, 7)
    }

    /// 阈值边界 0.15：恰好 0.15 配上，0.1500001 配不上（spec §10.3）
    func testGeometryFallbackThresholdBoundary() {
        // 恰好 0.15：y 差 0.15
        let at = ConservativeMatcher.match(
            snapshotWindows: [snapWin("app", "a", sibling: 0, x: 0.2, y: 0.2)],
            liveWindows: [live("app", "b", x: 0.2, y: 0.35, wid: 1)])
        XCTAssertEqual(at.matches.count, 1, "距离恰为阈值 0.15 应配上")

        let beyond = ConservativeMatcher.match(
            snapshotWindows: [snapWin("app", "a", sibling: 0, x: 0.2, y: 0.2)],
            liveWindows: [live("app", "b", x: 0.2, y: 0.351, wid: 1)])
        XCTAssertTrue(beyond.matches.isEmpty, "距离超阈值不得配上（保守匹配）")
        XCTAssertEqual(beyond.unmatchedSnapshotIndexes, [0])
    }

    /// 占用互斥：同应用两个失配快照条目抢同一个最近窗口 → 只有快照序在前者得到，后者跳过
    func testOccupancyMutualExclusion() {
        let snapshots = [
            snapWin("app", "t1", sibling: 0, x: 0.1, y: 0.1),
            snapWin("app", "t2", sibling: 0, x: 0.11, y: 0.1),  // 几何上同样最近
        ]
        let lives = [live("app", "-renamed", x: 0.1, y: 0.105, wid: 9)]  // 单个候选
        let outcome = ConservativeMatcher.match(snapshotWindows: snapshots, liveWindows: lives)
        XCTAssertEqual(outcome.matches.count, 1, "一个存活窗口只能被一个快照条目占用")
        XCTAssertEqual(outcome.matches[0].snapshotIndex, 0, "快照序在前者先占")
        XCTAssertEqual(outcome.unmatchedSnapshotIndexes, [1])
    }

    /// 不跨应用猜：失配条目不得配到别的应用的窗口，哪怕几何完全重合
    func testGeometryFallbackNeverCrossesApps() {
        let snapshots = [snapWin("app.a", "x", sibling: 0, x: 0.3, y: 0.3)]
        let lives = [live("app.b", "y", x: 0.3, y: 0.3, wid: 5)]  // 距离 0 但不同应用
        let outcome = ConservativeMatcher.match(snapshotWindows: snapshots, liveWindows: lives)
        XCTAssertTrue(outcome.matches.isEmpty)
    }

    /// 一级匹配优先：标题+兄弟序能配上时，不走几何兜底（近邻候选留给真正失配的条目）
    func testPrimaryMatchBeatsGeometryFallback() {
        let snapshots = [
            snapWin("app", "精确标题", sibling: 0, x: 0.9, y: 0.9),      // 一级可配
            snapWin("app", "失配标题", sibling: 0, x: 0.1, y: 0.1),      // 需要兜底
        ]
        let lives = [
            live("app", "精确标题", x: 0.9, y: 0.9, wid: 1),
            live("app", "-renamed", x: 0.15, y: 0.1, wid: 2),
        ]
        let outcome = ConservativeMatcher.match(snapshotWindows: snapshots, liveWindows: lives)
        XCTAssertEqual(outcome.matches.count, 2)
        XCTAssertFalse(outcome.matches.first { $0.snapshotIndex == 0 }!.viaGeometryFallback)
        XCTAssertEqual(outcome.matches.first { $0.snapshotIndex == 1 }!.viaGeometryFallback, true)
        XCTAssertEqual(lives[outcome.matches.first { $0.snapshotIndex == 1 }!.liveIndex].cgWindowID, 2)
    }

    /// 快照没有的窗口保留在 unmatchedLive（verify 推导「预期不动」集）
    func testUnmatchedLiveWindowsAreReported() {
        let outcome = ConservativeMatcher.match(
            snapshotWindows: [snapWin("app", "keep", sibling: 0, x: 0.1, y: 0.1)],
            liveWindows: [live("app", "keep", x: 0.1, y: 0.1, wid: 1),
                          live("app", "新开的", x: 0.8, y: 0.8, wid: 2)])
        XCTAssertEqual(outcome.unmatchedLiveIndexes, [1])
    }
}
