@testable import Core
import RestoreEngine
import SnapshotEngine
import XCTest

// 票 14 恢复管线单测（fake 注入驱动，spec §6.4/§6.7/§6.8/§7.1/§7.4）。
// 命名按用例矩阵：A7 已关闭应用不启动 / A8 快照外不动 / A9–A13 匹配与 Space 处置。

final class RestorePipelineTests: XCTestCase {
    let aOrigin = CGPoint(x: 0, y: 0), bOrigin = CGPoint(x: 2000, y: 0)
    let screenSize = CGSize(width: 1000, height: 1000)

    /// 标准场景：快照两条目（com.t.a「Doc」→A#1；com.t.gone「Gone」→B#1，应用已退出），
    /// 实况 = 101(com.t.a Doc，被折腾到 B#1) + 202(com.t.other「Extra」，快照外)。
    func makeWorld(bridgeAvailable: Bool = true) -> (snapshot: Snapshot, samples: [CGWindowSample],
                                                     bridge: FakeBridge, geometry: FakeGeometry,
                                                     log: LogSpy, store: SnapshotStore) {
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [
                World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000),
                World.topologyEntry(uuid: "B-uuid", name: "B", orientation: 0, x: 2000, y: 0, w: 1000, h: 1000),
            ],
            spaces: [World.userSpace("A-uuid", index: 1), World.userSpace("B-uuid", index: 1)],
            windows: [
                World.snapshotWindow(bundleID: "com.t.a", title: "Doc", sibling: 0,
                                     display: "A-uuid", space: 1, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
                World.snapshotWindow(bundleID: "com.t.gone", title: "Gone", sibling: 0,
                                     display: "B-uuid", space: 1, x: 0.1, y: 0.1, w: 0.2, h: 0.2),
            ])
        let samples = [
            World.sample(wid: 101, bundleID: "com.t.a", title: "Doc",
                         displayOrigin: bOrigin, displaySize: screenSize, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
            World.sample(wid: 202, bundleID: "com.t.other", title: "Extra",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.1, y: 0.6, w: 0.3, h: 0.3),
        ]
        let bridge = FakeBridge(
            entries: [World.entry("A-uuid", index: 1, id: 5), World.entry("B-uuid", index: 1, id: 6)],
            byWindow: [101: 6, 202: 5],
            bridgeAvailable: bridgeAvailable)
        return (snapshot, samples, bridge, FakeGeometry(), LogSpy(),
                SnapshotStore(directory: try! makeTempDir()))
    }

    func makeEngine(_ world: (snapshot: Snapshot, samples: [CGWindowSample], bridge: FakeBridge,
                              geometry: FakeGeometry, log: LogSpy, store: SnapshotStore),
                    rotation: [CGDirectDisplayID: Int] = [1: 0, 2: 0],
                    ax: WindowAXProbing = FakeAX(),
                    store: SnapshotStore? = nil) -> RestoreEngine {
        RestoreEngine(
            store: store ?? world.store,
            spaces: world.bridge,
            enumerator: FakeEnumerator(world.samples),
            ax: ax,
            geometry: world.geometry,
            displaysProvider: { World.displays() },
            rotationProvider: World.rotationProvider(rotation),
            log: world.log)
    }

    // MARK: A7/A8 + 回滚快照（§7.4）

    func testRestoreMovesMatchedSkipsQuitAppAndNeverTouchesOutOfSnapshotWindows() throws {
        let world = makeWorld()
        let engine = makeEngine(world)
        let key = SnapshotStore.topologyKey(forDisplayUUIDs: ["A-uuid", "B-uuid"])
        let undoURL = world.store.undoURL(topologyKey: key)

        let report = try engine.restore(snapshot: world.snapshot)

        // A7：已退出应用（com.t.gone）不启动 → 只 skip（reason=app-not-running），不产生任何动作
        XCTAssertTrue(world.log.all.contains { $0.contains("app=com.t.gone") && $0.contains("reason=app-not-running") },
                      "应记 skip 行 reason=app-not-running，实际：\(world.log.all)")
        XCTAssertTrue(world.bridge.moves.flatMap(\.wids).contains(101), "匹配窗口应被桥接移动")

        // A8：快照外窗口 202 一律不动 → 无桥接、无几何写
        XCTAssertFalse(world.bridge.moves.flatMap(\.wids).contains(202), "快照外窗口不得桥接移动")
        XCTAssertFalse(world.geometry.calls.map(\.windowID).contains(202), "快照外窗口不得写几何")

        // 匹配窗口 101：桥接回 A#1(id5) + 几何摆位（B 屏 → A 屏，比例 (0.1,0.1,0.4,0.4)）
        XCTAssertEqual(world.bridge.moves.count, 1)
        XCTAssertEqual(world.bridge.moves[0].wids, [101])
        XCTAssertEqual(world.bridge.moves[0].spaceID, 5)
        XCTAssertEqual(world.geometry.calls, [FakeGeometry.Call(windowID: 101,
                                                          position: CGPoint(x: 100, y: 100),
                                                          size: CGSize(width: 400, height: 400))])

        // 计数：ok=1（101）skip=1（com.t.gone）fail=0；matched=1；快照外=1
        XCTAssertEqual(report.okCount, 1)
        XCTAssertEqual(report.skipCount, 1)
        XCTAssertEqual(report.failCount, 0)
        XCTAssertEqual(report.matchedCount, 1)
        XCTAssertEqual(report.untouchedLiveCount, 1)

        // 回滚快照：恢复后存在，内容 = 恢复前实况（含快照外窗口）
        XCTAssertTrue(FileManager.default.fileExists(atPath: undoURL.path), "回滚快照应已落盘")
        let undo = try Snapshot.decode(from: Data(contentsOf: undoURL))
        XCTAssertEqual(undo.windows.count, 2, "回滚快照应记录恢复前全部实况窗口")
        XCTAssertTrue(undo.windows.contains { $0.bundleID == "com.t.other" })

        // 落盘顺序：undo 写入行必须先于首个 [restore] L2 动作行
        let undoIdx = try XCTUnwrap(world.log.all.firstIndex { $0.contains("undo-") && $0.contains("result=ok") })
        let firstActionIdx = try XCTUnwrap(world.log.all.firstIndex { $0.contains("[restore] L2") })
        XCTAssertLessThan(undoIdx, firstActionIdx, "动手恢复前必须先落回滚快照")
    }

    func testUndoWriteFailureAbortsBeforeAnyMutation() throws {
        // 存储目录路径被一个普通文件挡住 → 原子写必失败 → restore 中止且零动作（无撤销保险不动手）
        let dir = try makeTempDir()
        try Data("blocker".utf8).write(to: dir.appendingPathComponent("snapshots"))
        let blockedStore = SnapshotStore(directory: dir.appendingPathComponent("snapshots"))

        let world = makeWorld()
        let engine = makeEngine(world, store: blockedStore)
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000)],
            spaces: [World.userSpace("A-uuid", index: 1)],
            windows: [World.snapshotWindow(bundleID: "com.t.a", title: "Doc", sibling: 0,
                                           display: "A-uuid", space: 1, x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        XCTAssertThrowsError(try engine.restore(snapshot: snapshot)) { error in
            guard case RestoreEngineError.undoSnapshotWriteFailed = error else {
                return XCTFail("应抛 undoSnapshotWriteFailed，实际 \(error)")
            }
        }
        XCTAssertTrue(world.bridge.moves.isEmpty, "回滚快照写失败必须中止，不得动手")
        XCTAssertTrue(world.geometry.calls.isEmpty)
    }
}
