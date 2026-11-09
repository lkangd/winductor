@testable import Core
import RestoreEngine
import XCTest

// LiveWindowSetRestoreTests — 恢复实况集合走 Core.LiveWindowSet（票 dp-11；诊断 acceptance4 R1）。
// 实测：WeChat 隐藏 280×380「Weixin」窗（ordered out、与真主窗同标题）进实况集合 → 兄弟序/匹配歧义。

final class LiveWindowSetRestoreTests: XCTestCase {
    let aOrigin = CGPoint(x: 0, y: 0), bOrigin = CGPoint(x: 2000, y: 0)
    let screenSize = CGSize(width: 1000, height: 1000)

    /// 同标题隐藏幽灵窗（ordered out、非最小化）不入实况集合：快照条目配上真主窗，幽灵窗不被移动；
    /// 无 Space 归属的辅助窗同样不入（不计快照外窗口）
    func testOrderedOutGhostSiblingIsNotMatchedOrCounted() throws {
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [
                World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000),
                World.topologyEntry(uuid: "B-uuid", name: "B", orientation: 0, x: 2000, y: 0, w: 1000, h: 1000),
            ],
            spaces: [World.userSpace("A-uuid", index: 1), World.userSpace("B-uuid", index: 1)],
            windows: [World.snapshotWindow(bundleID: "com.tencent.xinWeChat", title: "Weixin", sibling: 0,
                                           display: "A-uuid", space: 1, x: 0.1, y: 0.1, w: 0.6, h: 0.6)])
        let samples = [
            // 幽灵：与主窗同标题、排序在前（y 更小）
            World.sample(wid: 1231, bundleID: "com.tencent.xinWeChat", title: "Weixin",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.0, y: 0.05, w: 0.28, h: 0.38,
                         onscreen: false),
            World.sample(wid: 1239, bundleID: "com.tencent.xinWeChat", title: "Weixin",
                         displayOrigin: bOrigin, displaySize: screenSize, x: 0.1, y: 0.3, w: 0.6, h: 0.6),
            // 无 Space 归属辅助窗
            World.sample(wid: 77, bundleID: "com.apple.TextInputUI.xpc.CursorUIViewService", title: nil,
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.0, y: 0.58, w: 0.05, h: 0.05),
        ]
        let bridge = FakeBridge(
            entries: [World.entry("A-uuid", index: 1, id: 5), World.entry("B-uuid", index: 1, id: 6)],
            byWindow: [1231: 5, 1239: 6])
        bridge.orderedOut = [1231]
        let geometry = FakeGeometry()
        let engine = RestoreEngine(
            store: PresetStore(directory: try makeTempDir()),
            spaces: bridge, enumerator: FakeEnumerator(samples), ax: FakeAX(),
            geometry: geometry,
            displaysProvider: { World.displays() },
            rotationProvider: World.rotationProvider([1: 0, 2: 0]), log: LogSpy())

        let report = try engine.restore(snapshot: snapshot)

        XCTAssertEqual(bridge.moves.map(\.wids), [[1239]], "配上真主窗，幽灵窗不动")
        XCTAssertEqual(geometry.calls.map(\.windowID), [1239])
        XCTAssertEqual(report.matchedCount, 1)
        XCTAssertEqual(report.untouchedLiveCount, 0, "幽灵窗与无归属辅助窗不入实况集合，不计快照外")
    }
}
