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
                                                     log: LogSpy, store: PresetStore) {
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
                PresetStore(directory: try! makeTempDir()))
    }

    func makeEngine(_ world: (snapshot: Snapshot, samples: [CGWindowSample], bridge: FakeBridge,
                              geometry: FakeGeometry, log: LogSpy, store: PresetStore),
                    rotation: [CGDirectDisplayID: Int] = [1: 0, 2: 0],
                    ax: WindowAXProbing = FakeAX(),
                    store: PresetStore? = nil) -> RestoreEngine {
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
        let key = Displays.topologyIdentity(of: World.displays(), rotation: { _ in 0 }).key
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
        let undoIdx = try XCTUnwrap(world.log.all.firstIndex { $0.contains("/undo.json") && $0.contains("result=ok") })
        let firstActionIdx = try XCTUnwrap(world.log.all.firstIndex { $0.contains("[restore] L2") })
        XCTAssertLessThan(undoIdx, firstActionIdx, "动手恢复前必须先落回滚快照")
    }

    /// 管线全程独占 SkyLight：执行中（L1 几何写时刻）后台 shared 一律跳过，结束后放行
    func testPipelineHoldsSkyLightSessionExclusively() throws {
        let world = makeWorld()
        let session = SkyLightSession()
        let engine = RestoreEngine(store: world.store, spaces: world.bridge,
                                   enumerator: FakeEnumerator(world.samples), ax: FakeAX(),
                                   geometry: world.geometry, session: session,
                                   displaysProvider: { World.displays() },
                                   rotationProvider: World.rotationProvider([1: 0, 2: 0]), log: world.log)
        var sharedDuringPipeline: Int?? = .none
        world.geometry.onApply = { sharedDuringPipeline = .some(session.shared { 1 }) }
        try engine.restore(snapshot: world.snapshot)

        XCTAssertEqual(sharedDuringPipeline, .some(nil), "管线执行中 shared 应被拦")
        XCTAssertEqual(session.shared { 1 }, 1, "管线结束后放行")
    }

    func testUndoWriteFailureAbortsBeforeAnyMutation() throws {
        // 存储目录路径被一个普通文件挡住 → 原子写必失败 → restore 中止且零动作（无撤销保险不动手）
        let dir = try makeTempDir()
        try Data("blocker".utf8).write(to: dir.appendingPathComponent("snapshots"))
        let blockedStore = PresetStore(directory: dir.appendingPathComponent("snapshots"))

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
            store: PresetStore(directory: try! makeTempDir()),
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
            store: PresetStore(directory: try makeTempDir()),
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
            store: PresetStore(directory: try! makeTempDir()),
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
            store: PresetStore(directory: try! makeTempDir()),
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
            store: PresetStore(directory: try! makeTempDir()),
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

    func testFullscreenSkipsPreMoveWhenSpaceAlreadyOnTargetDespiteStaleFrame() throws {
        // 屏归属以 Space 为准（GLOSSARY）：202 的 frame 是过期值仍落在 A，但 SLS 报它已在 B#1(id6)
        // = 已在目标屏 → 免桥接预移位，直接 AXFullScreen
        let world = makeFullscreenWorld()
        world.bridge.byWindow[202] = 6
        _ = try world.engine.restore(snapshot: world.snapshot)

        XCTAssertEqual(world.bridge.moves.map(\.wids), [[101]], "202 已在目标屏，不得预移位")
        XCTAssertEqual(world.fs.calls.map(\.windowID), [202])
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
            store: PresetStore(directory: try! makeTempDir()),
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
            store: PresetStore(directory: try! makeTempDir()),
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
            store: PresetStore(directory: try makeTempDir()),
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
            store: PresetStore(directory: try makeTempDir()),
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
        let deferred = DeferredGeometry(directory: try makeTempDir(), spaces: FakeBridge(entries: [], byWindow: [:]),
                                        session: SkyLightSession())
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
        let log = LogSpy()
        let engine = RestoreEngine(
            store: PresetStore(directory: try makeTempDir()),
            spaces: FakeBridge(
                entries: [World.entry("A-uuid", index: 1, id: 5), World.entry("B-uuid", index: 1, id: 6)],
                byWindow: [101: 5]),
            enumerator: FakeEnumerator(samples), ax: FakeAX(),
            geometry: geometry, deferredGeometry: deferred,
            displaysProvider: { World.displays() },
            rotationProvider: World.rotationProvider([1: 0, 2: 0]), log: log)

        _ = try engine.restore(snapshot: snapshot)

        let overrides = deferred.geometryOverrides()
        XCTAssertEqual(Array(overrides.keys), [101], "后台窗几何写失败 → pending 落盘")
        XCTAssertEqual(overrides[101]?.displayUUID, "A-uuid")
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
            store: PresetStore(directory: try makeTempDir()),
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
    /// 窗在后台 Space（不在任一屏活跃 Space）→ 不打 AX 写（4.7s/项），直接 pending 计 skip；
    /// 活跃窗照常 L1（精准口径优于 CG isOnscreen——后者对跨 Space 窗恒 true）
    func testWindowOnInactiveSpaceSkipsAXWriteToPending() throws {
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [
                World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000),
                World.topologyEntry(uuid: "B-uuid", name: "B", orientation: 0, x: 2000, y: 0, w: 1000, h: 1000),
            ],
            spaces: [World.userSpace("A-uuid", index: 1), World.userSpace("B-uuid", index: 1)],
            windows: [
                World.snapshotWindow(bundleID: "com.t.bg", title: "BG", sibling: 0,
                                     display: "A-uuid", space: 1, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
                World.snapshotWindow(bundleID: "com.t.fg", title: "FG", sibling: 0,
                                     display: "B-uuid", space: 1, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
            ])
        let samples = [
            World.sample(wid: 301, bundleID: "com.t.bg", title: "BG",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
            World.sample(wid: 302, bundleID: "com.t.fg", title: "FG",
                         displayOrigin: bOrigin, displaySize: screenSize, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
        ]
        let bridge = FakeBridge(
            entries: [World.entry("A-uuid", index: 1, id: 5), World.entry("B-uuid", index: 1, id: 6)],
            byWindow: [301: 5, 302: 6])
        bridge.activeSpaces = [6]  // A#1 非活跃（301 后台），B#1 活跃（302 可见）
        let geometry = FakeGeometry()
        let log = LogSpy()
        let engine = RestoreEngine(
            store: PresetStore(directory: try makeTempDir()),
            spaces: bridge, enumerator: FakeEnumerator(samples), ax: FakeAX(),
            geometry: geometry,
            displaysProvider: { World.displays() },
            rotationProvider: World.rotationProvider([1: 0, 2: 0]), log: log)

        XCTAssertEqual((try? bridge.activeSpaceIDs()) ?? [], [6], "fake 活跃集合注入验证")
        _ = try engine.restore(snapshot: snapshot)

        let calls = geometry.calls.map(\.windowID)
        XCTAssertFalse(calls.contains(301), "后台 Space 窗不打 AX 写; lines=\(log.all.joined(separator: " | "))")
        XCTAssertTrue(calls.contains(302), "活跃 Space 窗照常 L1")
        XCTAssertTrue(log.all.contains { $0.contains("wid=301") && $0.contains("offscreen-deferred") },
                      "后台窗落 pending 观测日志")
    }

    /// AX 写限时：单窗写超过 1.5s → 转延迟几何计 skip（不再拖死整轮，通知秒级），消费轮询兜底补写
    func testSlowAXApplyTimesOutToPending() throws {
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [
                World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000),
                World.topologyEntry(uuid: "B-uuid", name: "B", orientation: 0, x: 2000, y: 0, w: 1000, h: 1000),
            ],
            spaces: [World.userSpace("A-uuid", index: 1), World.userSpace("B-uuid", index: 1)],
            windows: [
                World.snapshotWindow(bundleID: "com.t.slow", title: "Slow", sibling: 0,
                                     display: "A-uuid", space: 1, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
            ])
        let samples = [
            World.sample(wid: 401, bundleID: "com.t.slow", title: "Slow",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
        ]
        let bridge = FakeBridge(
            entries: [World.entry("A-uuid", index: 1, id: 5), World.entry("B-uuid", index: 1, id: 6)],
            byWindow: [401: 5])
        bridge.activeSpaces = [5]  // 活跃窗（走 L1 AX 写路径）
        let geometry = FakeGeometry()
        geometry.applyDelay = 2.5  // 超过 1.5s 限时
        let log = LogSpy()
        let engine = RestoreEngine(
            store: PresetStore(directory: try makeTempDir()),
            spaces: bridge, enumerator: FakeEnumerator(samples), ax: FakeAX(),
            geometry: geometry,
            displaysProvider: { World.displays() },
            rotationProvider: World.rotationProvider([1: 0, 2: 0]), log: log)

        let report = try engine.restore(snapshot: snapshot)

        XCTAssertTrue(log.all.contains { $0.contains("ax-apply-timeout") }, "超时转延迟几何落日志")
        XCTAssertEqual(report.skipCount, 1, "超时计 skip（未尝试 ≠ 失败）")
        XCTAssertTrue(log.all.contains { $0.contains("wid=401") && $0.contains("result=skip") },
                      "L1 skip 行")
    }

    /// Applier：命中 pending 补写一次（一次性消费，重复调用不二次写）
    func testDeferredGeometryApplierConsumesPendingOnce() throws {
        let dir = try makeTempDir()
        let store = DeferredGeometryStore(directory: dir)
        store.save([PendingGeometryEntry(windowID: 7, displayUUID: "A-uuid", x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        let geometry = FakeGeometry()
        let applier = DeferredGeometryApplier(store: store, writer: geometry,
                                              displaysProvider: { World.displays() }, log: LogSpy(),
                                              frameReader: { _ in nil })

        XCTAssertTrue(applier.applyIfPending(windowID: 7), "命中 pending")
        XCTAssertEqual(geometry.calls.count, 1)
        XCTAssertFalse(applier.applyIfPending(windowID: 7), "一次性消费，不重复应用")
        XCTAssertTrue(store.load().isEmpty, "消费后清空")
    }

    /// 实测缺陷回归（11-03 第四轮 WeChat）：补写 AX 调用成功但实际高度仍缺 Dock 高度（写未生效/被
    /// app 回弹），一次性消费后再无补救。期望：写后回读，与目标不符计失败重试，并记实际值。
    func testDeferredGeometryApplierVerifiesWriteByReadBack() throws {
        let dir = try makeTempDir()
        let store = DeferredGeometryStore(directory: dir)
        store.save([PendingGeometryEntry(windowID: 7, displayUUID: "A-uuid", x: 0, y: 0.05, w: 1, h: 0.95)])
        let geometry = FakeGeometry()
        let log = LogSpy()
        // A 屏 1000×1000：目标 (0,50,1000,950)；回读高度少 55（躲 Dock）
        let frame = Unchecked(CGRect(x: 0, y: 50, width: 1000, height: 895))
        let applier = DeferredGeometryApplier(store: store, writer: geometry,
                                              displaysProvider: { World.displays() }, log: log,
                                              frameReader: { _ in frame.value })

        XCTAssertTrue(applier.applyIfPending(windowID: 7))
        XCTAssertEqual(store.load().first?.failedAttempts, 1, "回读不符：计失败保留重试")
        XCTAssertTrue(log.all.contains { $0.contains("readback-mismatch") && $0.contains("h=895") },
                      "记录实际回读值（定位 Dock 躲让/回弹）")

        frame.value = CGRect(x: 0, y: 50, width: 1000, height: 950)
        XCTAssertTrue(applier.applyIfPending(windowID: 7))
        XCTAssertTrue(store.load().isEmpty, "回读一致：消费")
    }

    /// 实测缺陷回归（11-03 第二轮 WeCom 缺 Dock 高度）：补写读整表 → AX 写阻塞数秒 → 写回整表；
    /// 阻塞期间新一轮恢复落盘的 pending 被旧表覆盖丢失（含 WeCom）。期望：只按 wid 原子删改，
    /// 新一轮同 wid 的新目标不被旧条目的消费删掉。
    func testDeferredGeometryApplierDoesNotClobberPendingWrittenDuringApply() throws {
        let dir = try makeTempDir()
        let store = DeferredGeometryStore(directory: dir)
        store.save([PendingGeometryEntry(windowID: 7, displayUUID: "A-uuid", x: 0.1, y: 0.1, w: 0.4, h: 0.4),
                    PendingGeometryEntry(windowID: 8, displayUUID: "A-uuid", x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        let nextRound = [PendingGeometryEntry(windowID: 7, displayUUID: "A-uuid", x: 0.2, y: 0.2, w: 0.5, h: 0.5),
                         PendingGeometryEntry(windowID: 28801, displayUUID: "A-uuid", x: 0, y: 0.05, w: 1, h: 0.95)]
        let geometry = FakeGeometry()
        geometry.onApply = { store.save(nextRound) }  // AX 写阻塞期间新一轮恢复整写替换
        let applier = DeferredGeometryApplier(store: store, writer: geometry,
                                              displaysProvider: { World.displays() }, log: LogSpy(),
                                              frameReader: { _ in nil })

        XCTAssertTrue(applier.applyIfPending(windowID: 7))
        XCTAssertEqual(store.load(), nextRound, "新一轮 pending 原样保留（旧 wid=7 的消费不删新目标，旧表不回写）")

        store.save([PendingGeometryEntry(windowID: 8, displayUUID: "A-uuid", x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        geometry.error = AXFacadeError.elementInvalid
        XCTAssertTrue(applier.applyIfPending(windowID: 8))
        XCTAssertEqual(store.load(), nextRound, "失败重试计数也不得把旧条目写回新一轮")
    }

    /// 实测缺陷回归（11-03 WeCom）：切到窗所在 Space 后首次补写 elementInvalid（AX 树滞后），
    /// 一次性丢弃 → 窗停在缩过的高度且被 poller 固化。期望：失败保留重试，达上限才丢弃。
    func testDeferredGeometryApplierRetriesFailedWriteUpToLimit() throws {
        let dir = try makeTempDir()
        let store = DeferredGeometryStore(directory: dir)
        store.save([PendingGeometryEntry(windowID: 7, displayUUID: "A-uuid", x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        let geometry = FakeGeometry()
        geometry.error = AXFacadeError.elementInvalid
        let applier = DeferredGeometryApplier(store: store, writer: geometry,
                                              displaysProvider: { World.displays() }, log: LogSpy(),
                                              frameReader: { _ in nil })

        for attempt in 1..<DeferredGeometryApplier.maxAttempts {
            XCTAssertTrue(applier.applyIfPending(windowID: 7))
            XCTAssertEqual(store.load().map(\.windowID), [7], "第 \(attempt) 次失败后保留待重试")
        }
        geometry.error = nil
        XCTAssertTrue(applier.applyIfPending(windowID: 7))
        XCTAssertEqual(geometry.calls.count, DeferredGeometryApplier.maxAttempts, "单窗入口不快速重试")
        XCTAssertTrue(store.load().isEmpty, "成功即消费")

        store.save([PendingGeometryEntry(windowID: 8, displayUUID: "A-uuid", x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        geometry.error = AXFacadeError.elementInvalid
        for _ in 0..<DeferredGeometryApplier.maxAttempts { applier.applyIfPending(windowID: 8) }
        XCTAssertTrue(store.load().isEmpty, "达上限丢弃（不无限重试）")
    }

    /// 提速（11-03 09:29 实测）：切到窗所在 Space 后动画期间窗尚未进 AX 树，首写 elementInvalid
    /// 白耗一次失败额度并要等下一个 2s tick。期望：批量补写按轮重建索引快速重试，不消耗失败额度。
    func testBatchApplyQuickRetriesAXMissingWindowsWithoutSpendingAttempt() throws {
        let dir = try makeTempDir()
        let store = DeferredGeometryStore(directory: dir)
        store.save([PendingGeometryEntry(windowID: 7, displayUUID: "A-uuid", x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        let geometry = FakeGeometry()
        geometry.error = AXFacadeError.elementInvalid
        geometry.onApply = { [unowned geometry] in
            if geometry.calls.count == 2 { geometry.error = nil }  // 第 3 轮时窗已进 AX 树
        }
        let log = LogSpy()
        let applier = DeferredGeometryApplier(store: store, writer: geometry,
                                              displaysProvider: { World.displays() }, log: log,
                                              frameReader: { _ in nil })

        applier.applyPending(windowIDs: [7], shouldYield: { false })

        XCTAssertEqual(geometry.calls.count, 3)
        XCTAssertTrue(store.load().isEmpty, "快速重试内成功即消费")
        XCTAssertFalse(log.all.contains { $0.contains("result=fail") }, "快速重试不计失败")
    }

    /// 实测回归（11-04 01:52）：Chrome 13 窗逐窗反查 + 每窗快速重试 ≈ 40 次 AX 枚举在 Chrome 主线程串行，
    /// 整批 19s。期望：每轮只建一次索引（同 app 多窗共用），只重试仍缺的窗；有界，末轮才计一次失败。
    func testBatchApplyPreparesIndexOncePerRoundAndRetriesOnlyMissingWindows() throws {
        let dir = try makeTempDir()
        let store = DeferredGeometryStore(directory: dir)
        store.save([PendingGeometryEntry(windowID: 7, displayUUID: "A-uuid", x: 0.1, y: 0.1, w: 0.4, h: 0.4),
                    PendingGeometryEntry(windowID: 8, displayUUID: "A-uuid", x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        let geometry = WindowFailingGeometry(failing: [8: AXFacadeError.elementInvalid])
        let applier = DeferredGeometryApplier(store: store, writer: geometry,
                                              displaysProvider: { World.displays() }, log: LogSpy(),
                                              frameReader: { _ in nil })

        applier.applyPending(windowIDs: [7, 8], shouldYield: { false })

        let rounds = 1 + DeferredGeometryApplier.elementInvalidQuickRetries
        XCTAssertEqual(geometry.prepared, [[7, 8]] + Array(repeating: [8], count: rounds - 1),
                       "每轮一次索引，只含仍缺的窗")
        XCTAssertEqual(geometry.calls(for: 7), 1, "已写成的窗不再重试")
        XCTAssertEqual(geometry.calls(for: 8), rounds)
        XCTAssertEqual(store.load().map(\.windowID), [8])
        XCTAssertEqual(store.load().first?.failedAttempts, 1, "整批快速重试只计一次失败")
    }

    /// 其他错误（如 -25200 kAXErrorFailure）不快速重试，直接计失败
    func testBatchApplyDoesNotQuickRetryOtherErrors() throws {
        let dir = try makeTempDir()
        let store = DeferredGeometryStore(directory: dir)
        store.save([PendingGeometryEntry(windowID: 8, displayUUID: "A-uuid", x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        let geometry = WindowFailingGeometry(failing: [8: AXFacadeError.failure(code: -25200)])
        let applier = DeferredGeometryApplier(store: store, writer: geometry,
                                              displaysProvider: { World.displays() }, log: LogSpy(),
                                              frameReader: { _ in nil })

        applier.applyPending(windowIDs: [8], shouldYield: { false })

        XCTAssertEqual(geometry.calls(for: 8), 1)
        XCTAssertEqual(store.load().first?.failedAttempts, 1)
    }

    /// 实测缺陷回归（11-03 第三轮 WeCom 缺底部）：串行补写时，排在前面的慢窗（Chrome 每条 ~4.7s）
    /// 让 WeCom 等到用户下一次拔屏都没轮到。期望：一个慢窗不挡其他窗。
    func testBatchApplySlowEntryDoesNotBlockOthers() throws {
        let dir = try makeTempDir()
        let store = DeferredGeometryStore(directory: dir)
        store.save([PendingGeometryEntry(windowID: 1, displayUUID: "A-uuid", x: 0.1, y: 0.1, w: 0.4, h: 0.4),
                    PendingGeometryEntry(windowID: 2, displayUUID: "A-uuid", x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        let finished = Unchecked([UInt32: Date]())
        let lock = NSLock()
        let applier = DeferredGeometryApplier(store: store, writer: FakeGeometry(),
                                              displaysProvider: { World.displays() }, log: LogSpy(),
                                              frameReader: { wid in
                                                  if wid == 1 { Thread.sleep(forTimeInterval: 0.6) }  // 慢窗
                                                  lock.lock(); finished.value[wid] = Date(); lock.unlock()
                                                  return nil
                                              })
        let start = Date()

        applier.applyPending(windowIDs: [1, 2], shouldYield: { false })

        XCTAssertLessThan(finished.value[2]?.timeIntervalSince(start) ?? .infinity, 0.3, "慢窗 1 不得阻塞窗 2")
        XCTAssertNotNil(finished.value[1])
    }

    /// 审查 #1：重试轮的等待期间恢复管线开工 → 不再建 AX 索引（与恢复管线争 AX）
    func testBatchApplyRechecksYieldAfterRetrySleep() throws {
        let dir = try makeTempDir()
        let store = DeferredGeometryStore(directory: dir)
        store.save([PendingGeometryEntry(windowID: 8, displayUUID: "A-uuid", x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        let geometry = WindowFailingGeometry(failing: [8: AXFacadeError.elementInvalid])
        let applier = DeferredGeometryApplier(store: store, writer: geometry,
                                              displaysProvider: { World.displays() }, log: LogSpy(),
                                              frameReader: { _ in nil })
        var yieldChecks = 0
        // 第 1 轮：循环入口 + 开工各查一次；第 2 轮入口仍放行，等待后（第 4 次）恢复已开工
        applier.applyPending(windowIDs: [8], shouldYield: { yieldChecks += 1; return yieldChecks >= 4 })

        XCTAssertEqual(geometry.prepared.count, 1, "等待后先查让出，再建索引")
    }

    func testBatchApplyYieldsWhenRestoreStarts() throws {
        let dir = try makeTempDir()
        let store = DeferredGeometryStore(directory: dir)
        store.save([PendingGeometryEntry(windowID: 1, displayUUID: "A-uuid", x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        let geometry = FakeGeometry()
        let applier = DeferredGeometryApplier(store: store, writer: geometry,
                                              displaysProvider: { World.displays() }, log: LogSpy(),
                                              frameReader: { _ in nil })

        applier.applyPending(windowIDs: [1], shouldYield: { true })

        XCTAssertTrue(geometry.calls.isEmpty, "恢复管线已开始：让出，不补写")
    }
}

/// 按窗注入失败的几何写桩（批量补写轮次断言：每轮 prepare 的窗集合 + 每窗写次数）
private final class WindowFailingGeometry: WindowGeometryWriting, @unchecked Sendable {
    private let lock = NSLock()
    private let failing: [UInt32: Error]
    private var _prepared: [[UInt32]] = []
    private var _calls: [UInt32: Int] = [:]
    init(failing: [UInt32: Error]) { self.failing = failing }
    var prepared: [[UInt32]] { lock.lock(); defer { lock.unlock() }; return _prepared }
    func calls(for wid: UInt32) -> Int { lock.lock(); defer { lock.unlock() }; return _calls[wid] ?? 0 }
    func prepare(windowIDs: [UInt32]) {
        lock.lock(); _prepared.append(windowIDs.sorted()); lock.unlock()
    }
    func apply(windowID: UInt32, position: CGPoint, size: CGSize) throws {
        lock.lock(); _calls[windowID, default: 0] += 1; lock.unlock()
        if let error = failing[windowID] { throw error }
    }
}

private final class Unchecked<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

// MARK: - 协作式取消（display-presets 票 04：恢复中拓扑变化 → 中止本轮，已移动窗口不回滚）

extension RestorePipelineTests {
    /// 首个桥接移动期间被取消 → 剩余条目不再移动、不写几何，报告标记 cancelled；回滚快照照常保留
    func testCancellationStopsRemainingItemsAndKeepsUndoSnapshot() throws {
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
        let cancellation = RestoreCancellation()
        bridge.moveHook = { cancellation.cancel() }  // 第一个窗口移动期间拓扑变了
        let geometry = FakeGeometry()
        let log = LogSpy()
        let store = PresetStore(directory: try makeTempDir())
        let engine = RestoreEngine(
            store: store, spaces: bridge, enumerator: FakeEnumerator(samples), ax: FakeAX(),
            geometry: geometry,
            displaysProvider: { World.displays() },
            rotationProvider: World.rotationProvider([1: 0, 2: 0]), log: log)

        let report = try engine.restore(snapshot: snapshot, preserveUndo: false, cancellation: cancellation)

        XCTAssertTrue(report.cancelled, "报告标记本轮被中止")
        XCTAssertEqual(bridge.moves.count, 1, "取消后剩余条目不再桥接移动（已移动的不回滚）")
        XCTAssertTrue(geometry.calls.isEmpty, "取消后不再写几何")
        XCTAssertTrue(log.all.contains { $0.contains("[restore] action=cancelled") }, "中止落日志")
        let key = Displays.topologyIdentity(of: World.displays(), rotation: { _ in 0 }).key
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.undoURL(topologyKey: key).path),
                      "回滚快照照常保留（可撤销）")
    }

    /// 未取消的令牌不改变管线行为
    func testUncancelledTokenRunsFullPipeline() throws {
        let world = makeWorld()
        let engine = makeEngine(world)
        let report = try engine.restore(snapshot: world.snapshot, preserveUndo: false,
                                        cancellation: RestoreCancellation())
        XCTAssertFalse(report.cancelled)
        XCTAssertEqual(report.okCount, 1)
    }
}

// MARK: L4 批量直移（display-presets 票 16：逐窗串行 1.2s × 12 窗 ≈ 13s → 同目标 Space 一次桥接）

extension RestorePipelineTests {
    /// 快照：101/102/103 最小化在 B#2(id7)，104 最小化在 B#1(id6)；实况四窗均最小化在 A#1(id5)
    func makeMultiMinimizedWorld() -> (snapshot: Snapshot, bridge: FakeBridge, mini: FakeMinimize,
                                       log: LogSpy, engine: RestoreEngine) {
        let apps: [(UInt32, String, Int)] = [(101, "com.t.a", 2), (102, "com.t.b", 2), (103, "com.t.c", 2),
                                             (104, "com.t.d", 1)]
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
            windows: apps.map {
                World.snapshotWindow(bundleID: $0.1, title: "W", sibling: 0, display: "B-uuid", space: $0.2,
                                     x: 0.1, y: 0.1, w: 0.4, h: 0.4, minimized: true)
            })
        let samples = apps.map {
            World.sample(wid: $0.0, bundleID: $0.1, title: "W", displayOrigin: aOrigin, displaySize: screenSize,
                         x: 0.2, y: 0.2, w: 0.4, h: 0.3, onscreen: false)
        }
        let bridge = FakeBridge(entries: [
            World.entry("A-uuid", index: 1, id: 5),
            World.entry("B-uuid", index: 1, id: 6),
            World.entry("B-uuid", index: 2, id: 7),
        ], byWindow: [101: 5, 102: 5, 103: 5, 104: 5])
        let mini = FakeMinimize()
        let log = LogSpy()
        let engine = RestoreEngine(
            store: PresetStore(directory: try! makeTempDir()),
            spaces: bridge, enumerator: FakeEnumerator(samples),
            ax: FakeAX(minimizedIDs: [101, 102, 103, 104]), geometry: FakeGeometry(),
            fullscreen: FakeFullScreen(), minimize: mini, fullscreenSettleSeconds: 0,
            displaysProvider: { World.displays() },
            rotationProvider: World.rotationProvider([1: 0, 2: 0]), log: log)
        return (snapshot, bridge, mini, log, engine)
    }

    func testMinimizedWindowsSharingTargetSpaceBridgeOnceThenFallBackPerWindow() throws {
        let world = makeMultiMinimizedWorld()
        world.bridge.minimizedDirectMoveFailIDs = [102]
        let report = try world.engine.restore(snapshot: world.snapshot)

        let batches = world.bridge.directMinimizedBatches
        XCTAssertEqual(batches.count, 2, "按目标 Space 分组：B#2 一次、B#1 一次")
        XCTAssertEqual(batches.first { $0.spaceID == 7 }.map { Set($0.wids) }, [101, 102, 103])
        XCTAssertEqual(batches.first { $0.spaceID == 6 }.map(\.wids), [104])

        // 组内未迁移的 102 逐窗走 §6.5 回退；其余不碰 AXMinimized
        XCTAssertEqual(world.mini.calls.map(\.windowID), [102, 102])
        XCTAssertEqual(world.mini.calls.map(\.value), [false, true])
        XCTAssertEqual(world.bridge.moves.map(\.wids), [[102]])
        XCTAssertEqual(world.bridge.moves.map(\.spaceID), [7])

        // 逐窗 restoreLine 口径与计数不变
        let l4 = world.log.all.filter { $0.contains("[restore] L4") && $0.contains("action=minimize") }
        XCTAssertEqual(l4.count, 4, "实际：\(l4)")
        for wid in [101, 102, 103, 104] {
            XCTAssertTrue(l4.contains { $0.contains("wid=\(wid)") && $0.contains("result=ok") }, "wid=\(wid)：\(l4)")
        }
        XCTAssertEqual(report.okCount, 4); XCTAssertEqual(report.failCount, 0); XCTAssertEqual(report.skipCount, 0)
    }
}
