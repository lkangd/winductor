@testable import Core
import AXFacade  // AxFacadeError.elementInvalid：后台窗延迟几何触发条件
import RestoreEngine
import SpaceAdapter  // SpaceAdapterError.layerUnavailable：L2 层失效连坐分类（票 15）
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
        // 统一 §10.4 格式：规划期整窗 skip 按首个动作层 L2 记（target = 快照意愿；未配对 wid=0）
        let skipLine = try XCTUnwrap(world.log.all.first {
            $0.contains("app=com.t.gone") && $0.contains("reason=app-not-running") },
            "应记 skip 行 reason=app-not-running，实际：\(world.log.all)")
        XCTAssertTrue(skipLine.contains("[restore] L2 wid=0 app=com.t.gone action=move-to-space"),
                      "skip 行应走统一格式化器（冻结字段 + reason 扩展键），实际：\(skipLine)")
        XCTAssertTrue(skipLine.contains("target=B-uuid/1 before=- after=- result=skip"),
                      "skip 行应携带快照意愿 target 与 result=skip，实际：\(skipLine)")
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

    func testMinimizedLiveWindowRestoredViaL4AndSnapshotMinimizedEntryExpandedRestoredNormally() throws {
        // 票 15 L4 归口更新：实况最小化窗口一律经 L4（直移回快照 Space 并保持最小化）；
        // 快照 minimized 但实况已展开的条目走常规恢复（终态是否最小化尊重实况，不强行重新最小化）
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

        // 101（实况最小化，快照 Doc 未最小化）→ L4：目标 A#1(id5) 已在 → 直移 true，零首尾动作
        XCTAssertEqual(bridge.directMinimizedMoves.map(\.windowID), [101])
        // 102 走常规桥接；101 不出现在常规桥接列表（已走 L4 直移）
        XCTAssertEqual(bridge.moves.map(\.wids), [[102]])
        XCTAssertTrue(geometry.calls.map(\.windowID).contains(101) == false, "最小化窗几何不触碰")

        // 102（快照 Mini minimized=true，实况已展开）→ 常规恢复：几何照写（尊重实况展开态）
        XCTAssertEqual(geometry.calls.map(\.windowID), [102])
        XCTAssertEqual(report.okCount, 2, "101 L4 ok + 102 常规 ok")
        XCTAssertEqual(report.skipCount, 0)
        XCTAssertEqual(report.failCount, 0)
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

// MARK: L3 全屏最后（票 15，A17）— 快照 fullscreen Space（kind=fullscreen 携带 bundleID）恢复

extension RestorePipelineTests {
    /// A17 场景：双屏。快照 = A#1 user + B#1 user + B#2 fullscreen(com.t.fs)；
    /// 实况 = 101(com.t.a Doc，被折腾到 B#1) + 202(com.t.fs Full，全屏应用窗现落在 A 整屏)。
    /// 全屏应用不进 snapshot.windows（schema §7.3），由 fullscreen Space 携带 bundleID 表示。
    func makeFullscreenWorld(fsWindowLive: Bool = true) -> (snapshot: Snapshot, bridge: FakeBridge,
                                                            geometry: FakeGeometry, fs: FakeFullScreen,
                                                            log: LogSpy, engine: RestoreEngine) {
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [
                World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000),
                World.topologyEntry(uuid: "B-uuid", name: "B", orientation: 0, x: 2000, y: 0, w: 1000, h: 1000),
            ],
            spaces: [
                World.userSpace("A-uuid", index: 1),
                World.userSpace("B-uuid", index: 1),
                SnapshotSpace(displayUUID: "B-uuid", index: 2, kind: .fullscreen,
                              fullscreenAppBundleID: "com.t.fs"),
            ],
            windows: [World.snapshotWindow(bundleID: "com.t.a", title: "Doc", sibling: 0,
                                           display: "A-uuid", space: 1, x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        var samples = [
            World.sample(wid: 101, bundleID: "com.t.a", title: "Doc",
                         displayOrigin: bOrigin, displaySize: screenSize, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
        ]
        if fsWindowLive {
            samples.append(World.sample(wid: 202, bundleID: "com.t.fs", title: "Full",
                                        displayOrigin: aOrigin, displaySize: screenSize,
                                        x: 0.0, y: 0.0, w: 1.0, h: 1.0))
        }
        var byWindow: [UInt32: Int64] = [101: 6]
        if fsWindowLive { byWindow[202] = 5 }
        let bridge = FakeBridge(
            entries: [World.entry("A-uuid", index: 1, id: 5), World.entry("B-uuid", index: 1, id: 6)],
            byWindow: byWindow)
        let geometry = FakeGeometry()
        let fs = FakeFullScreen()
        let log = LogSpy()
        let engine = RestoreEngine(
            store: SnapshotStore(directory: try! makeTempDir()),
            spaces: bridge, enumerator: FakeEnumerator(samples),
            ax: FakeAX(), geometry: geometry,
            fullscreen: fs, minimize: FakeMinimize(), fullscreenSettleSeconds: 0,
            displaysProvider: { World.displays() },
            rotationProvider: World.rotationProvider([1: 0, 2: 0]), log: log)
        return (snapshot, bridge, geometry, fs, log, engine)
    }

    func testFullscreenAppRestoredLastOntoSnapshotDisplayAndGeometryUntouched() throws {
        // A17：全屏应用恢复至快照屏 type=4 Space，且发生在该屏其余落位之后；全屏窗几何不再触碰
        let world = makeFullscreenWorld()
        let report = try world.engine.restore(snapshot: world.snapshot)

        // 目标屏就位：L2 先归位 101 → A#1(id5)，L3 预移位 202 → B 屏既有 Space(B#1 id6)（05 #4）
        XCTAssertEqual(world.bridge.moves.map(\.wids), [[101], [202]], "L2 常规窗在前，L3 预移位在后")
        XCTAssertEqual(world.bridge.moves.map(\.spaceID), [5, 6])

        // 全屏窗几何不触碰（票面验收：全屏恢复后窗口几何不再被触碰）
        XCTAssertEqual(world.geometry.calls.map(\.windowID), [101], "几何只动常规窗")

        // AXFullScreen=true 恰一次、对 202（进入后台可完成，§5.2/§8.6）
        XCTAssertEqual(world.fs.calls.map(\.windowID), [202])
        XCTAssertEqual(world.fs.calls.map(\.value), [true])

        // 顺序铁律（§6.8 全屏最后）：L1 几何（101）必须先于 L3 全屏（202）
        let l1Idx = try XCTUnwrap(world.log.all.firstIndex {
            $0.contains("[restore] L1") && $0.contains("wid=101") && $0.contains("result=ok") })
        let l3Idx = try XCTUnwrap(world.log.all.firstIndex {
            $0.contains("[restore] L3") && $0.contains("action=fullscreen") && $0.contains("result=ok") })
        XCTAssertLessThan(l1Idx, l3Idx, "全屏必须在该屏其余落位完成之后")

        // 计数：常规窗 1 ok + 全屏 Space 1 ok；无跳过无失败
        XCTAssertEqual(report.okCount, 2)
        XCTAssertEqual(report.skipCount, 0)
        XCTAssertEqual(report.failCount, 0)
    }
}

extension RestorePipelineTests {
    func testFullscreenLayerDegradedSkipsFullscreenButRestoresTheRest() throws {
        // A20 同构（FORCE_DEGRADED=fullscreen 走同一 isLayerAvailable 判定路径）：
        // L3 降级只降该层 —— 全屏应用不动，L2/L1 照常
        let world = makeFullscreenWorld()
        world.bridge.layerAvailability[.fullscreen] = false
        let report = try world.engine.restore(snapshot: world.snapshot)

        XCTAssertTrue(world.fs.calls.isEmpty, "L3 降级不写全屏")
        XCTAssertEqual(world.bridge.moves.map(\.wids), [[101]], "常规窗 L2 照常")
        XCTAssertEqual(world.geometry.calls.map(\.windowID), [101], "L1 照常")
        XCTAssertFalse(world.bridge.moves.flatMap(\.wids).contains(202), "降级层不动全屏应用窗")

        // 降级 skip 行：无具体窗口可归（未选窗），统一 §10.4 格式（wid=0 + reason 扩展键）
        let skipLine = try XCTUnwrap(world.log.all.first {
            $0.contains("[restore] L3") && $0.contains("result=skip") && $0.contains("app=com.t.fs") })
        XCTAssertTrue(skipLine.contains("wid=0") && skipLine.contains("reason=fullscreen-layer-unavailable"),
                      "实际：\(skipLine)")

        XCTAssertEqual(report.okCount, 1)
        XCTAssertEqual(report.skipCount, 1)
        XCTAssertEqual(report.failCount, 0, "降级 skip 不计失败")
    }

    func testFullscreenSkipsAsAppNotRunningWhenAppHasNoLiveWindow() throws {
        // 全屏应用已退出（§6.4a 不启动）→ 该 fullscreen Space 跳过，不产生任何动作
        let world = makeFullscreenWorld(fsWindowLive: false)
        let report = try world.engine.restore(snapshot: world.snapshot)

        XCTAssertTrue(world.fs.calls.isEmpty)
        XCTAssertTrue(world.bridge.moves.flatMap(\.wids).contains(202) == false)
        let line = try XCTUnwrap(world.log.all.first {
            $0.contains("app=com.t.fs") && $0.contains("reason=app-not-running") })
        XCTAssertTrue(line.contains("result=skip") || line.contains("skip"), "实际：\(line)")
        XCTAssertEqual(report.okCount, 1, "只剩常规窗 101 ok")
        XCTAssertEqual(report.skipCount, 1)
        XCTAssertEqual(report.failCount, 0)
    }
}

// MARK: L4 最小化恢复（票 15，A16）— 送回快照 Space 并保持最小化

extension RestorePipelineTests {
    /// A16 场景：双屏。快照 = com.t.m「Mail」→ B#2（minimized=true）；
    /// 实况 = 101 Mail 最小化（isOnscreen=false，CG 契约），在原 Space A#1(id5)。
    func makeMinimizedWorld() -> (snapshot: Snapshot, bridge: FakeBridge, geometry: FakeGeometry,
                                  mini: FakeMinimize, log: LogSpy, engine: RestoreEngine) {
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [
                World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000),
                World.topologyEntry(uuid: "B-uuid", name: "B", orientation: 0, x: 2000, y: 0, w: 1000, h: 1000),
            ],
            spaces: [
                World.userSpace("A-uuid", index: 1),
                World.userSpace("B-uuid", index: 1),
                World.userSpace("B-uuid", index: 2),
            ],
            windows: [World.snapshotWindow(bundleID: "com.t.m", title: "Mail", sibling: 0,
                                           display: "B-uuid", space: 2, x: 0.1, y: 0.1, w: 0.4, h: 0.4,
                                           minimized: true)])
        let samples = [
            World.sample(wid: 101, bundleID: "com.t.m", title: "Mail",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.2, y: 0.2, w: 0.4, h: 0.3,
                         onscreen: false),
        ]
        let bridge = FakeBridge(entries: [
            World.entry("A-uuid", index: 1, id: 5),
            World.entry("B-uuid", index: 1, id: 6),
            World.entry("B-uuid", index: 2, id: 7),
        ], byWindow: [101: 5])
        let geometry = FakeGeometry()
        let mini = FakeMinimize()
        let log = LogSpy()
        let engine = RestoreEngine(
            store: SnapshotStore(directory: try! makeTempDir()),
            spaces: bridge, enumerator: FakeEnumerator(samples),
            ax: FakeAX(minimizedIDs: [101]), geometry: geometry,
            fullscreen: FakeFullScreen(), minimize: mini, fullscreenSettleSeconds: 0,
            displaysProvider: { World.displays() },
            rotationProvider: World.rotationProvider([1: 0, 2: 0]), log: log)
        return (snapshot, bridge, geometry, mini, log, engine)
    }

    func testMinimizedWindowSentBackToSnapshotSpaceAndStaysMinimizedViaDirectBridge() throws {
        // A16：最小化窗直移可行（§6.5）→ 送回快照 Space 且保持最小化，零首尾 AXMinimized 动作
        let world = makeMinimizedWorld()
        let report = try world.engine.restore(snapshot: world.snapshot)

        XCTAssertEqual(world.bridge.directMinimizedMoves.map(\.windowID), [101],
                       "先试最小化状态直接桥接")
        XCTAssertEqual(world.bridge.directMinimizedMoves.map(\.spaceID), [7],
                       "目标 = 快照 Space B#2(id7)")
        XCTAssertTrue(world.mini.calls.isEmpty, "直移成功不触碰 AXMinimized")
        XCTAssertTrue(world.bridge.moves.isEmpty, "不走常规 moveWindowsToSpace")
        XCTAssertTrue(world.geometry.calls.isEmpty, "最小化窗几何不触碰")
        XCTAssertEqual(world.bridge.byWindow[101], 7, "归属实际变更到快照 Space")

        let l4 = try XCTUnwrap(world.log.all.first {
            $0.contains("[restore] L4") && $0.contains("action=minimize") })
        XCTAssertTrue(l4.contains("wid=101") && l4.contains("result=ok"), "实际：\(l4)")

        XCTAssertEqual(report.okCount, 1)
        XCTAssertEqual(report.skipCount, 0)
        XCTAssertEqual(report.failCount, 0)
    }
}

extension RestorePipelineTests {
    func testMinimizedWindowFallsBackToUnminimizeBridgeReminimizeWhenDirectBridgeFails() throws {
        // §6.5 回退：直移不可行 → 取消最小化（落回原 Space）→ 桥接 → 重新最小化，语义不变
        let world = makeMinimizedWorld()
        world.bridge.minimizedDirectMoveFails = true
        let report = try world.engine.restore(snapshot: world.snapshot)

        XCTAssertEqual(world.mini.calls.map(\.windowID), [101, 101])
        XCTAssertEqual(world.mini.calls.map(\.value), [false, true], "取消最小化 → 重新最小化")
        XCTAssertEqual(world.bridge.moves.map(\.wids), [[101]])
        XCTAssertEqual(world.bridge.moves.map(\.spaceID), [7], "取消后桥接移至快照 Space")
        XCTAssertEqual(report.okCount, 1); XCTAssertEqual(report.failCount, 0); XCTAssertEqual(report.skipCount, 0)
    }

    func testMinimizedWindowCountsFailWhenFallbackBridgeIsSilentNoOp() throws {
        // 回退桥接 no-op（perform 后归属未变更）→ 计失败（同 L2 口径）；仍尽力重最小化保持终态
        let world = makeMinimizedWorld()
        world.bridge.minimizedDirectMoveFails = true
        world.bridge.moveReturnsFalse = true
        let report = try world.engine.restore(snapshot: world.snapshot)

        XCTAssertEqual(world.mini.calls.map(\.value), [false, true], "终态仍恢复最小化")
        XCTAssertEqual(report.failCount, 1); XCTAssertEqual(report.okCount, 0)
        XCTAssertTrue(world.log.all.contains {
            $0.contains("[restore] L4") && $0.contains("result=fail") })
    }

    func testMinimizedWindowSkipsWhenBridgeLayerUnavailableInFallback() throws {
        // L2 层失效连坐（探针未过 / 运行时 no-op 已标死）：重最小化后原地保持，按 skip 不判本窗失败
        let world = makeMinimizedWorld()
        world.bridge.minimizedDirectMoveFails = true
        world.bridge.moveError = SpaceAdapterError.layerUnavailable(.bridge)
        let report = try world.engine.restore(snapshot: world.snapshot)

        XCTAssertEqual(world.mini.calls.map(\.value), [false, true], "终态原地保持最小化")
        XCTAssertEqual(report.skipCount, 1); XCTAssertEqual(report.failCount, 0); XCTAssertEqual(report.okCount, 0)
        XCTAssertTrue(world.log.all.contains {
            $0.contains("[restore] L4") && $0.contains("result=skip") })
    }

    func testMinimizedWindowCountsFailWhenBridgeMoveErrorsUnexpectedly() throws {
        // 非层失效类桥接错误（如 bridgedOpFailed）→ 计失败
        let world = makeMinimizedWorld()
        world.bridge.minimizedDirectMoveFails = true
        world.bridge.moveError = FakeAXPermissionError()
        let report = try world.engine.restore(snapshot: world.snapshot)

        XCTAssertEqual(report.failCount, 1); XCTAssertEqual(report.okCount, 0); XCTAssertEqual(report.skipCount, 0)
        XCTAssertTrue(world.log.all.contains { $0.contains("[restore] detail wid=101") })
    }

    func testMinimizedWindowCountsFailWhenUnminimizeWriteFails() throws {
        // 取消最小化 AX 写失败 → 计失败，窗口保持最小化原地
        let world = makeMinimizedWorld()
        world.bridge.minimizedDirectMoveFails = true
        world.mini.error = FakeAXPermissionError()
        let report = try world.engine.restore(snapshot: world.snapshot)

        XCTAssertEqual(world.mini.calls.map(\.value), [false], "取消最小化失败后不再重最小化")
        XCTAssertEqual(report.failCount, 1); XCTAssertEqual(report.okCount, 0); XCTAssertEqual(report.skipCount, 0)
    }
}

// MARK: 降级阶梯逐层独立（票 15，A20/A21 同构：FORCE_DEGRADED 走同一 isLayerAvailable 判定路径）

extension RestorePipelineTests {
    /// 混合场景：A#1 user + B#1/#2 user + B#3 fullscreen(com.t.fs)；
    /// 实况 = 101 Doc 在 B#1（常规）、202 fs 在 A 整屏（全屏应用）、301 Mail 最小化在 A#1。
    func makeMixedWorld() -> (snapshot: Snapshot, bridge: FakeBridge, geometry: FakeGeometry,
                              fs: FakeFullScreen, mini: FakeMinimize, log: LogSpy, engine: RestoreEngine) {
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [
                World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000),
                World.topologyEntry(uuid: "B-uuid", name: "B", orientation: 0, x: 2000, y: 0, w: 1000, h: 1000),
            ],
            spaces: [
                World.userSpace("A-uuid", index: 1),
                World.userSpace("B-uuid", index: 1),
                World.userSpace("B-uuid", index: 2),
                SnapshotSpace(displayUUID: "B-uuid", index: 3, kind: .fullscreen,
                              fullscreenAppBundleID: "com.t.fs"),
            ],
            windows: [
                World.snapshotWindow(bundleID: "com.t.a", title: "Doc", sibling: 0,
                                     display: "A-uuid", space: 1, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
                World.snapshotWindow(bundleID: "com.t.m", title: "Mail", sibling: 0,
                                     display: "B-uuid", space: 2, x: 0.1, y: 0.1, w: 0.4, h: 0.4,
                                     minimized: true),
            ])
        let samples = [
            World.sample(wid: 101, bundleID: "com.t.a", title: "Doc",
                         displayOrigin: bOrigin, displaySize: screenSize, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
            World.sample(wid: 202, bundleID: "com.t.fs", title: "Full",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.0, y: 0.0, w: 1.0, h: 1.0),
            World.sample(wid: 301, bundleID: "com.t.m", title: "Mail",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.2, y: 0.2, w: 0.4, h: 0.3,
                         onscreen: false),
        ]
        let bridge = FakeBridge(entries: [
            World.entry("A-uuid", index: 1, id: 5),
            World.entry("B-uuid", index: 1, id: 6),
            World.entry("B-uuid", index: 2, id: 8),
        ], byWindow: [101: 6, 202: 5, 301: 5])
        let geometry = FakeGeometry()
        let fs = FakeFullScreen()
        let mini = FakeMinimize()
        let log = LogSpy()
        let engine = RestoreEngine(
            store: SnapshotStore(directory: try! makeTempDir()),
            spaces: bridge, enumerator: FakeEnumerator(samples),
            ax: FakeAX(minimizedIDs: [301]), geometry: geometry,
            fullscreen: fs, minimize: mini, fullscreenSettleSeconds: 0,
            displaysProvider: { World.displays() },
            rotationProvider: World.rotationProvider([1: 0, 2: 0]), log: log)
        return (snapshot, bridge, geometry, fs, mini, log, engine)
    }

    func testMinimizedLayerUnavailableLeavesWindowUntouchedAsSkipWhileOthersProceed() throws {
        // A21 同构：FORCE_DEGRADED=minimized → L4 降级：最小化窗原地保持最小化不动、不报失败（skip）
        let world = makeMixedWorld()
        world.bridge.layerAvailability[.minimized] = false
        let report = try world.engine.restore(snapshot: world.snapshot)

        // L4 失效路径：零动作（无直移、无 AXMinimized 写、无几何、无桥接）
        XCTAssertTrue(world.bridge.directMinimizedMoves.isEmpty)
        XCTAssertTrue(world.mini.calls.isEmpty)
        XCTAssertFalse(world.geometry.calls.map(\.windowID).contains(301))
        XCTAssertFalse(world.bridge.moves.flatMap(\.wids).contains(301))

        let skip = try XCTUnwrap(world.log.all.first {
            $0.contains("[restore] L4") && $0.contains("action=minimize") && $0.contains("result=skip") })
        XCTAssertTrue(skip.contains("wid=301"), "实际：\(skip)")

        // 其余层照常：101 L2+L1、202 L3 全屏
        XCTAssertEqual(world.bridge.moves.map(\.wids), [[101], [202]])
        XCTAssertEqual(world.geometry.calls.map(\.windowID), [101])
        XCTAssertEqual(world.fs.calls.map(\.windowID), [202])

        XCTAssertEqual(report.okCount, 2, "101 常规 + L3 全屏")
        XCTAssertEqual(report.skipCount, 1, "L4 降级 skip")
        XCTAssertEqual(report.failCount, 0, "L4 降级不报失败")
    }

    func testFullscreenLayerDegradedKeepsMinimizedLayerWorking() throws {
        // FORCE_DEGRADED=fullscreen 语义：L3 降级全屏应用不动，L4 最小化恢复照常
        let world = makeMixedWorld()
        world.bridge.layerAvailability[.fullscreen] = false
        let report = try world.engine.restore(snapshot: world.snapshot)

        XCTAssertTrue(world.fs.calls.isEmpty, "L3 降级不写全屏")
        XCTAssertFalse(world.bridge.moves.flatMap(\.wids).contains(202), "全屏应用窗不预移位")

        XCTAssertEqual(world.bridge.directMinimizedMoves.map(\.windowID), [301], "L4 照常")
        XCTAssertTrue(world.mini.calls.isEmpty, "直移成功无首尾动作")
        XCTAssertEqual(world.bridge.byWindow[301], 8, "送回快照 Space B#2(id8)")

        // L2/L1 照常
        XCTAssertEqual(world.bridge.moves.map(\.wids), [[101]])
        XCTAssertEqual(world.geometry.calls.map(\.windowID), [101])

        XCTAssertEqual(report.okCount, 2, "101 常规 + 301 L4")
        XCTAssertEqual(report.skipCount, 1, "L3 降级 skip")
        XCTAssertEqual(report.failCount, 0)
    }
}

// MARK: - 桥接超时降级（实测缺陷：WindowServer 迁移单窗可阻塞 159s，超时后本轮剩余桥接项快速跳过）

extension RestorePipelineTests {
    /// 第 1 个桥接移动后桥接失效 → 第 2 个条目跳过 L2（不再碰桥）但仍走 L1 几何
    func testBridgeDegradedMidRunSkipsRemainingBridgeMovesButKeepsGeometry() throws {
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
                World.snapshotWindow(bundleID: "com.t.b", title: "Mail", sibling: 0,
                                     display: "A-uuid", space: 1, x: 0.5, y: 0.1, w: 0.4, h: 0.4),
            ])
        // 实况两窗都跑到 B#1（快照外位置）→ 都需要桥接移回 A#1
        let samples = [
            World.sample(wid: 101, bundleID: "com.t.a", title: "Doc",
                         displayOrigin: bOrigin, displaySize: screenSize, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
            World.sample(wid: 202, bundleID: "com.t.b", title: "Mail",
                         displayOrigin: bOrigin, displaySize: screenSize, x: 0.5, y: 0.1, w: 0.4, h: 0.4),
        ]
        let bridge = FakeBridge(
            entries: [World.entry("A-uuid", index: 1, id: 5), World.entry("B-uuid", index: 1, id: 6)],
            byWindow: [101: 6, 202: 6])
        bridge.degradeBridgeAfterMoves = 1  // 第 1 次移动后桥接失效（超时降级模拟）
        let geometry = FakeGeometry()
        let log = LogSpy()
        let engine = RestoreEngine(
            store: SnapshotStore(directory: try makeTempDir()),
            spaces: bridge, enumerator: FakeEnumerator(samples), ax: FakeAX(),
            geometry: geometry, displaysProvider: { World.displays() },
            rotationProvider: World.rotationProvider([1: 0, 2: 0]), log: log)

        _ = try engine.restore(snapshot: snapshot)

        XCTAssertEqual(bridge.moves.count, 1, "失效后不再碰桥（实测：后续调用被同一楔死拖住 111s）")
        XCTAssertEqual(geometry.calls.count, 2, "L1 几何照常，两窗都摆位")
        let skipLines = log.all.filter { $0.contains("[restore] L2") && $0.contains("result=skip") }
        XCTAssertEqual(skipLines.count, 1, "失效后剩余桥接项记 skip")
    }
}

// MARK: - 管线死线（实测缺陷：系统级楔死可把通知拖到数分钟后；死线保证计数有界到达）

extension RestorePipelineTests {
    /// 桥接每窗阻塞 > 死线 → 死线触发、剩余项计 skip、restore 在有界时间内返回
    func testPipelineDeadlineMarksRemainingItemsSkippedAndReturnsBounded() throws {
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
                World.snapshotWindow(bundleID: "com.t.b", title: "Mail", sibling: 0,
                                     display: "A-uuid", space: 1, x: 0.5, y: 0.1, w: 0.4, h: 0.4),
            ])
        let samples = [
            World.sample(wid: 101, bundleID: "com.t.a", title: "Doc",
                         displayOrigin: bOrigin, displaySize: screenSize, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
            World.sample(wid: 202, bundleID: "com.t.b", title: "Mail",
                         displayOrigin: bOrigin, displaySize: screenSize, x: 0.5, y: 0.1, w: 0.4, h: 0.4),
        ]
        let bridge = FakeBridge(
            entries: [World.entry("A-uuid", index: 1, id: 5), World.entry("B-uuid", index: 1, id: 6)],
            byWindow: [101: 6, 202: 6])
        // 每次桥接移动阻塞 0.3s（模拟楔死）
        bridge.moveHook = { Thread.sleep(forTimeInterval: 0.3) }
        let log = LogSpy()
        let engine = RestoreEngine(
            store: SnapshotStore(directory: try makeTempDir()),
            spaces: bridge, enumerator: FakeEnumerator(samples), ax: FakeAX(),
            geometry: FakeGeometry(),
            pipelineDeadlineSeconds: 0.1,
            displaysProvider: { World.displays() },
            rotationProvider: World.rotationProvider([1: 0, 2: 0]), log: log)

        let start = Date()
        let report = try engine.restore(snapshot: snapshot)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 5.0, "死线保证有界返回")
        XCTAssertTrue(log.all.contains { $0.contains("action=deadline") }, "死线触发要落日志")
        XCTAssertEqual(report.okCount + report.skipCount + report.failCount,
                       3, "计数闭合不丢条目：ok 1 + 死线跳过 1 + 缺席 skip 1")
    }
}

// MARK: - 后台窗延迟几何（实测缺陷：AX 树只含可见 Space 窗，后台窗几何写 elementInvalid）

extension RestorePipelineTests {
    /// L1 写后台窗报 elementInvalid → pending 落盘（延迟单次应用的数据源）
    func testBackgroundWindowGeometryDeferredToPendingFile() throws {
        let dir = try makeTempDir()
        let deferred = DeferredGeometryStore(directory: dir)
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
            ])
        let samples = [
            World.sample(wid: 101, bundleID: "com.t.a", title: "Doc",
                         displayOrigin: bOrigin, displaySize: screenSize, x: 0.1, y: 0.1, w: 0.4, h: 0.4,
                         onscreen: false),  // 后台窗：AX 不可见
        ]
        let geometry = FakeGeometry()
        geometry.error = AXFacadeError.elementInvalid
        let deferredStore = DeferredGeometryStore(directory: dir)
        let log = LogSpy()
        let engine = RestoreEngine(
            store: SnapshotStore(directory: try makeTempDir()),
            spaces: FakeBridge(
                entries: [World.entry("A-uuid", index: 1, id: 5), World.entry("B-uuid", index: 1, id: 6)],
                byWindow: [101: 5]),
            enumerator: FakeEnumerator(samples), ax: FakeAX(),
            geometry: geometry, deferredGeometry: deferredStore,
            displaysProvider: { World.displays() },
            rotationProvider: World.rotationProvider([1: 0, 2: 0]), log: log)

        _ = try engine.restore(snapshot: snapshot)

        let entries = deferred.load()
        XCTAssertEqual(entries.count, 1, "后台窗几何写失败 → pending 落盘")
        XCTAssertEqual(entries.first?.windowID, 101)
        XCTAssertEqual(entries.first?.displayUUID, "A-uuid")
        XCTAssertTrue(log.all.contains { $0.contains("offscreen-deferred") }, "落观测日志")
        XCTAssertTrue(log.all.contains { $0.contains("wid=101") && $0.contains("action=position") && $0.contains("result=skip") },
                      "后台窗 L1 计 skip（未尝试 ≠ 失败）")
        XCTAssertTrue(geometry.calls.isEmpty, "不打 AX 写（4.7s/项超时的来源，实测 13 项 = 61s）")
    }

    /// poller 并发冲突导致 SLS 清单首读失败 → 重试一次即成功，L2 不再整轮 skip（11-03 实测）
    func testSpaceListFirstReadFailureRetriesOnceAndRestoresL2() throws {
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [
                World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000),
                World.topologyEntry(uuid: "B-uuid", name: "B", orientation: 0, x: 2000, y: 0, w: 1000, h: 1000),
            ],
            spaces: [World.userSpace("A-uuid", index: 1), World.userSpace("B-uuid", index: 1)],
            windows: [
                World.snapshotWindow(bundleID: "com.t.a", title: "Doc", sibling: 0,
                                     display: "B-uuid", space: 1, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
            ])
        let samples = [
            World.sample(wid: 201, bundleID: "com.t.a", title: "Doc",
                         displayOrigin: bOrigin, displaySize: screenSize, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
        ]
        let bridge = FakeBridge(
            entries: [World.entry("A-uuid", index: 1, id: 5), World.entry("B-uuid", index: 1, id: 6)],
            byWindow: [201: 6])
        bridge.managedSpacesFailures = 2  // undo 快照读 + 管线首读都失败，重试即成功
        let log = LogSpy()
        let engine = RestoreEngine(
            store: SnapshotStore(directory: try makeTempDir()),
            spaces: bridge, enumerator: FakeEnumerator(samples), ax: FakeAX(),
            geometry: FakeGeometry(), displaysProvider: { World.displays() },
            rotationProvider: World.rotationProvider([1: 0, 2: 0]), log: log)

        let report = try engine.restore(snapshot: snapshot)

        XCTAssertTrue(log.all.contains { $0.contains("action=space-list") && $0.contains("result=retry") },
                      "首读失败落观测日志; lines=\(log.all.joined(separator: " | "))")
        XCTAssertFalse(log.all.contains { $0.contains("result=failed detail=L2-will-skip") },
                       "重试成功不应落终局失败日志")
        let bridgeLine = log.all.first { $0.contains("wid=201") && $0.contains("move-to-space") }
        XCTAssertNotNil(bridgeLine, "重试成功后 L2 正常执行")
        XCTAssertFalse(bridgeLine?.contains("result=skip") ?? true, "L2 不再整轮 skip")
        _ = report
    }
}

extension RestorePipelineTests {
    /// Applier：命中 pending 补写一次（一次性消费，重复调用不二次写）
    func testDeferredGeometryApplierConsumesPendingOnce() throws {
        let dir = try makeTempDir()
        let store = DeferredGeometryStore(directory: dir)
        store.save([PendingGeometryEntry(windowID: 7, displayUUID: "A-uuid", x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        let geometry = FakeGeometry()
        let applier = DeferredGeometryApplier(store: store, writer: geometry,
                                              displaysProvider: { World.displays() }, log: LogSpy())

        XCTAssertTrue(applier.applyIfPending(windowID: 7), "命中 pending")
        XCTAssertEqual(geometry.calls.count, 1)
        XCTAssertFalse(applier.applyIfPending(windowID: 7), "一次性消费，不重复应用")
        XCTAssertTrue(store.load().isEmpty, "消费后清空")
    }
}
