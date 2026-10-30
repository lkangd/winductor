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

// MARK: A12/A13 — Space 数量不符双向处置（spec §6.7）

extension RestorePipelineTests {
    func singleDisplayEngine(snapshot: Snapshot, samples: [CGWindowSample],
                             bridge: FakeBridge, geometry: FakeGeometry,
                             log: LogSpy, rotation: Int = 0) -> RestoreEngine {
        RestoreEngine(
            store: SnapshotStore(directory: try! makeTempDir()),
            spaces: bridge,
            enumerator: FakeEnumerator(samples),
            ax: FakeAX(),
            geometry: geometry,
            displaysProvider: { [Displays.Info(id: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                               uuid: "A-uuid")] },
            rotationProvider: World.rotationProvider([1: rotation]),
            log: log)
    }

    func testSnapshotSpaceBeyondExistingMergesToNearestWithLog() throws {
        // A12：快照目标 A#2，现状 A 屏只剩 #1 → 按 index 就近并入 id5 + space-merge 日志（不补建）
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000)],
            spaces: [World.userSpace("A-uuid", index: 1), World.userSpace("A-uuid", index: 2)],
            windows: [World.snapshotWindow(bundleID: "com.t.a", title: "Doc", sibling: 0,
                                           display: "A-uuid", space: 2, x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        let samples = [World.sample(wid: 101, bundleID: "com.t.a", title: "Doc",
                                    displayOrigin: aOrigin, displaySize: screenSize, x: 0.5, y: 0.1, w: 0.4, h: 0.4)]
        let bridge = FakeBridge(entries: [World.entry("A-uuid", index: 1, id: 5)], byWindow: [101: 5])
        let geometry = FakeGeometry()
        let log = LogSpy()
        let engine = singleDisplayEngine(snapshot: snapshot, samples: samples,
                                         bridge: bridge, geometry: geometry, log: log)

        let report = try engine.restore(snapshot: snapshot)

        XCTAssertEqual(bridge.moves.count, 1)
        XCTAssertEqual(bridge.moves[0].wids, [101])
        XCTAssertEqual(bridge.moves[0].spaceID, 5, "应就近并入既有 #1")
        XCTAssertTrue(log.all.contains { $0.contains("space-merge") && $0.contains("snapshotIndex=2 mergedTo=1") },
                      "应记 space-merge 行，实际：\(log.all)")
        XCTAssertTrue(log.all.contains { $0.contains("action=move-to-space target=A-uuid/1") && $0.contains("result=ok") })
        XCTAssertEqual(report.okCount, 1); XCTAssertEqual(report.failCount, 0); XCTAssertEqual(report.skipCount, 0)
        XCTAssertEqual(geometry.calls.map(\.windowID), [101], "并入后几何摆位照常")
    }

    func testCurrentSpacesBeyondSnapshotPlaceByIndexNormally() throws {
        // A13：现状多出（A 屏 #1..#3，快照只记 #2/#3）→ 照 index 正常落位，无 space-merge 行
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000)],
            spaces: [World.userSpace("A-uuid", index: 1), World.userSpace("A-uuid", index: 2),
                     World.userSpace("A-uuid", index: 3)],
            windows: [
                World.snapshotWindow(bundleID: "com.t.a", title: "Doc", sibling: 0,
                                     display: "A-uuid", space: 2, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
                World.snapshotWindow(bundleID: "com.t.b", title: "Term", sibling: 0,
                                     display: "A-uuid", space: 3, x: 0.5, y: 0.1, w: 0.4, h: 0.4),
            ])
        let samples = [
            World.sample(wid: 101, bundleID: "com.t.a", title: "Doc",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.1, y: 0.6, w: 0.4, h: 0.3),
            World.sample(wid: 102, bundleID: "com.t.b", title: "Term",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.5, y: 0.6, w: 0.4, h: 0.3),
        ]
        let bridge = FakeBridge(entries: [World.entry("A-uuid", index: 1, id: 5),
                                          World.entry("A-uuid", index: 2, id: 6),
                                          World.entry("A-uuid", index: 3, id: 7)],
                                byWindow: [101: 5, 102: 5])
        let geometry = FakeGeometry()
        let log = LogSpy()
        let engine = singleDisplayEngine(snapshot: snapshot, samples: samples,
                                         bridge: bridge, geometry: geometry, log: log)

        let report = try engine.restore(snapshot: snapshot)

        XCTAssertEqual(bridge.moves.count, 2)
        XCTAssertEqual(bridge.moves[0].wids, [101]); XCTAssertEqual(bridge.moves[0].spaceID, 6)
        XCTAssertEqual(bridge.moves[1].wids, [102]); XCTAssertEqual(bridge.moves[1].spaceID, 7)
        XCTAssertFalse(log.all.contains { $0.contains("space-merge") }, "现状多出不产生 merge 行")
        XCTAssertEqual(report.okCount, 2); XCTAssertEqual(report.failCount, 0)
    }

    func testBridgeUnavailableSkipsMoveButStillPositions() throws {
        // FORCE_DEGRADED=bridge 等效：L2 降级 skip 行 + L1 几何照常（spec §6.1 逐层降级）
        let world = makeWorld(bridgeAvailable: false)
        let engine = makeEngine(world)

        let report = try engine.restore(snapshot: world.snapshot)

        XCTAssertTrue(world.bridge.moves.isEmpty, "L2 不可用不得调用桥接")
        XCTAssertTrue(world.log.all.contains {
            $0.contains("[restore] L2") && $0.contains("action=move-to-space") && $0.contains("result=skip") },
            "应记 L2 skip 行，实际：\(world.log.all)")
        XCTAssertEqual(world.geometry.calls, [FakeGeometry.Call(windowID: 101,
                                                           position: CGPoint(x: 100, y: 100),
                                                           size: CGSize(width: 400, height: 400))],
                       "L1 几何照常")
        XCTAssertEqual(report.okCount, 1, "降级 skip 不计失败")
        XCTAssertEqual(report.failCount, 0)
    }

    func testMinimizedSnapshotEntryAndLiveMinimizedWindowAreSkipped() throws {
        // L4 本票不碰（票 15）：快照 minimized 条目 skip；实况最小化窗口 skip
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000)],
            spaces: [World.userSpace("A-uuid", index: 1)],
            windows: [
                World.snapshotWindow(bundleID: "com.t.a", title: "Doc", sibling: 0,
                                     display: "A-uuid", space: 1, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
                World.snapshotWindow(bundleID: "com.t.b", title: "Mini", sibling: 0,
                                     display: "A-uuid", space: 1, x: 0.5, y: 0.1, w: 0.4, h: 0.4,
                                     minimized: true),
            ])
        let samples = [
            World.sample(wid: 101, bundleID: "com.t.a", title: "Doc",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.1, y: 0.6, w: 0.4, h: 0.3,
                         onscreen: false),  // 最小化窗口 isOnscreen=false（CG 契约），AX minimized 由此读到
            World.sample(wid: 102, bundleID: "com.t.b", title: "Mini",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.5, y: 0.6, w: 0.4, h: 0.3),
        ]
        let bridge = FakeBridge(entries: [World.entry("A-uuid", index: 1, id: 5)], byWindow: [101: 5, 102: 5])
        let geometry = FakeGeometry()
        let log = LogSpy()
        let engine = RestoreEngine(
            store: SnapshotStore(directory: try makeTempDir()),
            spaces: bridge, enumerator: FakeEnumerator(samples),
            ax: FakeAX(minimizedIDs: [101]),  // 101 实况最小化
            geometry: geometry,
            displaysProvider: { [Displays.Info(id: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                                               uuid: "A-uuid")] },
            rotationProvider: World.rotationProvider([1: 0]), log: log)

        let report = try engine.restore(snapshot: snapshot)

        XCTAssertTrue(bridge.moves.isEmpty, "最小化条目/窗口一律不动")
        XCTAssertTrue(geometry.calls.isEmpty)
        XCTAssertTrue(log.all.contains { $0.contains("reason=live-minimized") })
        XCTAssertTrue(log.all.contains { $0.contains("reason=minimized-entry-L4") })
        XCTAssertEqual(report.skipCount, 2); XCTAssertEqual(report.okCount, 0); XCTAssertEqual(report.failCount, 0)
    }
}

// MARK: L1 几何摆位 — 比例坐标 × 所属屏 bounds + 旋转轴向互换 + AX 失败路径

extension RestorePipelineTests {
    /// 双屏场景：窗口 101 实况在 A 屏，快照要求落 B 屏（跨屏桥接 + 几何按 B 屏 bounds 摆位）
    func makeCrossScreenWorld(capturedBOrientation: Int, currentBOrientation: Int,
                              geometryError: Error? = nil) -> (Snapshot, FakeBridge, FakeGeometry, LogSpy, RestoreEngine) {
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [
                World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000),
                World.topologyEntry(uuid: "B-uuid", name: "B", orientation: capturedBOrientation,
                                    x: 2000, y: 0, w: 1000, h: 500),
            ],
            spaces: [World.userSpace("A-uuid", index: 1), World.userSpace("B-uuid", index: 1)],
            windows: [World.snapshotWindow(bundleID: "com.t.a", title: "Doc", sibling: 0,
                                           display: "B-uuid", space: 1, x: 0.1, y: 0.2, w: 0.5, h: 0.6)])
        let samples = [World.sample(wid: 101, bundleID: "com.t.a", title: "Doc",
                                    displayOrigin: aOrigin, displaySize: screenSize, x: 0.3, y: 0.3, w: 0.4, h: 0.4)]
        let bridge = FakeBridge(entries: [World.entry("A-uuid", index: 1, id: 5),
                                          World.entry("B-uuid", index: 1, id: 6)],
                                byWindow: [101: 5])
        let geometry = FakeGeometry()
        geometry.error = geometryError
        let log = LogSpy()
        let engine = RestoreEngine(
            store: SnapshotStore(directory: try! makeTempDir()),
            spaces: bridge, enumerator: FakeEnumerator(samples), ax: FakeAX(), geometry: geometry,
            displaysProvider: { [Displays.Info(id: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), uuid: "A-uuid"),
                                    Displays.Info(id: 2, bounds: CGRect(x: 2000, y: 0, width: 1000, height: 500), uuid: "B-uuid")] },
            rotationProvider: World.rotationProvider([1: 0, 2: currentBOrientation]), log: log)
        return (snapshot, bridge, geometry, log, engine)
    }

    func testGeometryIsRatioTimesTargetDisplayBounds() throws {
        // 同旋转：比例 (0.1,0.2,0.5,0.6) × B 屏 bounds (2000,0,1000,500) → 绝对 pos/size
        let (snapshot, bridge, geometry, log, engine) = makeCrossScreenWorld(
            capturedBOrientation: 0, currentBOrientation: 0)

        _ = try engine.restore(snapshot: snapshot)

        XCTAssertEqual(bridge.moves[0].spaceID, 6, "先桥接移到 B 屏 Space")
        XCTAssertEqual(geometry.calls, [FakeGeometry.Call(windowID: 101,
                                                          position: CGPoint(x: 2000 + 0.1 * 1000, y: 0.2 * 500),
                                                          size: CGSize(width: 0.5 * 1000, height: 0.6 * 500))])
        XCTAssertTrue(log.all.contains { $0.contains("[restore] L1") && $0.contains("action=position")
            && $0.contains("result=ok") && $0.contains("target=B-uuid rot=0") },
            "应记 L1 ok 行，实际：\(log.all)")
    }

    func testRotationChangeSwapsAxesBestEffort() throws {
        // A14 雏形：捕获竖屏 90° vs 当前横屏 0° → 比例轴向互换 (x,y,w,h)→(y,x,h,w)
        let (snapshot, _, geometry, log, engine) = makeCrossScreenWorld(
            capturedBOrientation: 90, currentBOrientation: 0)

        _ = try engine.restore(snapshot: snapshot)

        // 互换后比例 (0.2,0.1,0.6,0.5) × B 屏 (2000,0,1000,500) → pos (2200,50) size (600,250)
        XCTAssertEqual(geometry.calls, [FakeGeometry.Call(windowID: 101,
                                                          position: CGPoint(x: 2200, y: 50),
                                                          size: CGSize(width: 600, height: 250))])
        XCTAssertTrue(log.all.contains { $0.contains("target=B-uuid rot=0") })
    }

    func testAXPermissionDeniedCountsFailAndLogs() throws {
        // 「AX 权限不足」路径 = 验收行为：L2 已完成、L1 result=fail + 详情行 + 计数 fail（不中断）
        let (snapshot, bridge, geometry, log, engine) = makeCrossScreenWorld(
            capturedBOrientation: 0, currentBOrientation: 0,
            geometryError: FakeAXPermissionError())

        let report = try engine.restore(snapshot: snapshot)

        XCTAssertEqual(bridge.moves.count, 1, "L2 已执行（逐层降级：单动作失败不影响他层已完成的动作）")
        XCTAssertTrue(log.all.contains { $0.contains("[restore] L1") && $0.contains("action=position")
            && $0.contains("result=fail") }, "应记 L1 fail 行，实际：\(log.all)")
        XCTAssertTrue(log.all.contains { $0.contains("[restore] detail") && $0.contains("action=position") },
            "失败详情应独立成行")
        XCTAssertEqual(report.failCount, 1)
        XCTAssertEqual(report.okCount, 0)
        XCTAssertEqual(report.skipCount, 0)
    }
}

// MARK: A9/A10/A11 — 管线级匹配行为 + one-shot 幂等（§6.3）

extension RestorePipelineTests {
    func testTitleMismatchFallsBackToGeometryWithinThreshold() throws {
        // A9：标题失配（浏览器切 tab）→ 二级几何兜底成功，动作照常落到该窗口
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000)],
            spaces: [World.userSpace("A-uuid", index: 1)],
            windows: [World.snapshotWindow(bundleID: "com.t.a", title: "Old Tab", sibling: 0,
                                           display: "A-uuid", space: 1, x: 0.2, y: 0.3, w: 0.4, h: 0.4)])
        let samples = [World.sample(wid: 101, bundleID: "com.t.a", title: "New Tab",
                                    displayOrigin: aOrigin, displaySize: screenSize, x: 0.2, y: 0.3, w: 0.4, h: 0.4)]
        let bridge = FakeBridge(entries: [World.entry("A-uuid", index: 1, id: 5)], byWindow: [101: 5])
        let geometry = FakeGeometry()
        let log = LogSpy()
        let engine = singleDisplayEngine(snapshot: snapshot, samples: samples,
                                         bridge: bridge, geometry: geometry, log: log)

        let report = try engine.restore(snapshot: snapshot)

        XCTAssertEqual(geometry.calls.map(\.windowID), [101], "兜底配上的窗口应照常摆位")
        XCTAssertEqual(report.matchedCount, 1)
        XCTAssertEqual(report.okCount, 1)
        XCTAssertTrue(log.all.contains { $0.contains("app=com.t.a") && $0.contains("action=position") })
    }

    func testTitleMismatchFarAwayStaysUntouched() throws {
        // A10：标题失配且几何兜底失败（距离超阈）→ 保守跳过不动
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000)],
            spaces: [World.userSpace("A-uuid", index: 1)],
            windows: [World.snapshotWindow(bundleID: "com.t.a", title: "Old Tab", sibling: 0,
                                           display: "A-uuid", space: 1, x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        let samples = [World.sample(wid: 101, bundleID: "com.t.a", title: "New Tab",
                                    displayOrigin: aOrigin, displaySize: screenSize, x: 0.9, y: 0.9, w: 0.4, h: 0.4)]
        let bridge = FakeBridge(entries: [World.entry("A-uuid", index: 1, id: 5)], byWindow: [101: 5])
        let geometry = FakeGeometry()
        let log = LogSpy()
        let engine = singleDisplayEngine(snapshot: snapshot, samples: samples,
                                         bridge: bridge, geometry: geometry, log: log)

        let report = try engine.restore(snapshot: snapshot)

        XCTAssertTrue(bridge.moves.isEmpty)
        XCTAssertTrue(geometry.calls.isEmpty)
        XCTAssertTrue(log.all.contains { $0.contains("reason=unmatched") })
        XCTAssertEqual(report.skipCount, 1)
        XCTAssertEqual(report.untouchedLiveCount, 1)
    }

    func testSameTitleWindowsAlignBySiblingOrder() throws {
        // A11：同应用同标题双窗 → 存活侧按「先 y 后 x」排序，与快照 siblingIndex 对位
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
                World.snapshotWindow(bundleID: "com.t.a", title: "Doc", sibling: 1,
                                     display: "B-uuid", space: 1, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
            ])
        // 存活侧：111 在上方（y=0.1 → sibling 0），222 在下方（y=0.5 → sibling 1）
        let samples = [
            World.sample(wid: 222, bundleID: "com.t.a", title: "Doc",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.1, y: 0.5, w: 0.4, h: 0.4),
            World.sample(wid: 111, bundleID: "com.t.a", title: "Doc",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
        ]
        let bridge = FakeBridge(entries: [World.entry("A-uuid", index: 1, id: 5),
                                          World.entry("B-uuid", index: 1, id: 6)],
                                byWindow: [111: 5, 222: 5])
        let geometry = FakeGeometry()
        let log = LogSpy()
        let engine = RestoreEngine(
            store: SnapshotStore(directory: try! makeTempDir()),
            spaces: bridge, enumerator: FakeEnumerator(samples), ax: FakeAX(), geometry: geometry,
            displaysProvider: { World.displays() },
            rotationProvider: World.rotationProvider([1: 0, 2: 0]), log: log)

        let report = try engine.restore(snapshot: snapshot)

        // sibling 0 → A#1(id5) 对 111；sibling 1 → B#1(id6) 对 222
        let byWid = Dictionary(uniqueKeysWithValues: bridge.moves.map { ($0.wids[0], $0.spaceID) })
        XCTAssertEqual(byWid[111], 5)
        XCTAssertEqual(byWid[222], 6)
        XCTAssertEqual(report.okCount, 2)
        XCTAssertEqual(report.failCount, 0)
    }

    func testRerunAfterRestoreIsStableNoDrift() throws {
        // one-shot 幂等（§6.3/§9.3）：恢复完成后再跑一轮 → 归属与几何不再漂移、计数不劣化
        let world = makeWorld()
        let engine = makeEngine(world)

        let first = try engine.restore(snapshot: world.snapshot)
        let stateAfterFirst = world.bridge.byWindow
        let geometryAfterFirst = world.geometry.calls

        let second = try engine.restore(snapshot: world.snapshot)

        XCTAssertEqual(world.bridge.byWindow, stateAfterFirst, "复跑不改变 Space 归属")
        XCTAssertEqual(world.geometry.calls.count, geometryAfterFirst.count * 2, "复跑重写同一批几何（值恒等）")
        XCTAssertEqual(world.geometry.calls.suffix(geometryAfterFirst.count), geometryAfterFirst,
                       "复跑写入的 pos/size 与首轮逐值相同")
        XCTAssertEqual(first.okCount, second.okCount)
        XCTAssertEqual(second.failCount, 0)
        XCTAssertEqual(second.skipCount, first.skipCount)
    }
}
