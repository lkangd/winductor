@testable import Core
import CoreGraphics
import Foundation
import RestoreEngine
import SnapshotEngine
import SpaceAdapter
import XCTest

// UndoTests.swift — 票 16 撤销管线单测（fake 注入驱动，spec §6.3/§7.4/§8.6；用例 A18/A19）。
// 撤销语义 = 把回滚快照（undo-<拓扑键>.json，恢复前实况）当作恢复目标跑一次恢复管线；
// 回滚快照撤销后保留（重复撤销幂等无害，spec §7.4）；含全屏应用走两段式（§8.6）。
// 场景自含（与 RestorePipelineTests 不共享状态）：
//   U（恢复前实况 = 回滚目标）：101 常规窗 A#1 (0.1,0.1,0.4,0.4) + 202 常规窗 A#1 (0.55,0.55,0.3,0.3)；
//   S（恢复目标）：101 → B#1 (0.5,0.5,0.3,0.3)。restore(S) 打乱后 undo 读 undo 文件回滚到 U。

/// 可变实况枚举 fake：两段式撤销需在「恢复后 / 按 Esc 后」实况态之间切换
final class MutableEnumerator: WindowEnumerating, @unchecked Sendable {
    var samples: [CGWindowSample]
    init(_ samples: [CGWindowSample]) { self.samples = samples }
    func sample() -> [CGWindowSample] { samples }
}

/// 撤销测试自含 AX 桩：fullScreen 可注入（SnapshotComposer 写回滚快照时按其把整屏窗归为全屏应用，spec §7.3）
struct UndoFakeAX: WindowAXProbing {
    var fullScreenIDs: Set<UInt32> = []
    func probe(pid: Int32, windowID: UInt32) -> WindowAXState {
        WindowAXState(minimized: false, fullScreen: fullScreenIDs.contains(windowID))
    }
}

/// 撤销测试世界：restore 与 undo 两阶段共用同一组 fake（引用类型，阶段间按用例推进实况/Space 态）
struct UndoWorld {
    /// S 恢复目标
    let snapshot: Snapshot
    /// U 实况（恢复前，即回滚快照内容来源）
    let initialSamples: [CGWindowSample]
    let ax: UndoFakeAX
    let bridge: FakeBridge
    let geometry: FakeGeometry
    let fullscreen: FakeFullScreen
    let log: LogSpy
    let store: SnapshotStore
}

final class UndoPipelineTests: XCTestCase {
    let aOrigin = CGPoint(x: 0, y: 0), bOrigin = CGPoint(x: 2000, y: 0)
    let screenSize = CGSize(width: 1000, height: 1000)

    /// 回滚快照路径（A/B 双屏拓扑键）
    func undoURL(_ store: SnapshotStore) -> URL {
        store.undoURL(topologyKey: SnapshotStore.topologyKey(forDisplayUUIDs: ["A-uuid", "B-uuid"]))
    }

    /// 无全屏场景（A18）：U = 101(A#1, 0.1,0.1,0.4,0.4) + 202(A#1, 0.55,0.55,0.3,0.3)；S = 101 → B#1 (0.5,0.5,0.3,0.3)
    func makeWorld() -> UndoWorld {
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [
                World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000),
                World.topologyEntry(uuid: "B-uuid", name: "B", orientation: 0, x: 2000, y: 0, w: 1000, h: 1000),
            ],
            spaces: [World.userSpace("A-uuid", index: 1), World.userSpace("B-uuid", index: 1)],
            windows: [World.snapshotWindow(bundleID: "com.t.a", title: "Doc", sibling: 0,
                                           display: "B-uuid", space: 1, x: 0.5, y: 0.5, w: 0.3, h: 0.3)])
        let initialSamples = [
            World.sample(wid: 101, bundleID: "com.t.a", title: "Doc",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
            World.sample(wid: 202, bundleID: "com.t.other", title: "Extra",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.55, y: 0.55, w: 0.3, h: 0.3),
        ]
        return UndoWorld(
            snapshot: snapshot,
            initialSamples: initialSamples,
            ax: UndoFakeAX(),
            bridge: FakeBridge(
                entries: [World.entry("A-uuid", index: 1, id: 5), World.entry("B-uuid", index: 1, id: 6)],
                byWindow: [101: 5, 202: 5]),
            geometry: FakeGeometry(),
            fullscreen: FakeFullScreen(),
            log: LogSpy(),
            store: SnapshotStore(directory: try! makeTempDir()))
    }

    func makeEngine(_ world: UndoWorld, samples: [CGWindowSample]? = nil) -> RestoreEngine {
        RestoreEngine(
            store: world.store,
            spaces: world.bridge,
            enumerator: MutableEnumerator(samples ?? world.initialSamples),
            ax: world.ax,
            geometry: world.geometry,
            fullscreen: world.fullscreen,
            minimize: FakeMinimize(),
            fullscreenSettleSeconds: 0,
            displaysProvider: { World.displays() },
            rotationProvider: World.rotationProvider([1: 0, 2: 0]),
            log: world.log)
    }

    // MARK: 入口安全（spec §7.4「仅文件存在时可用」；票面「缺失/损坏入口禁用不崩溃」）

    func testUndoWithoutUndoFileIsDisabledWithExplicitError() throws {
        let world = makeWorld()
        let engine = makeEngine(world)

        XCTAssertFalse(engine.canUndo(), "回滚快照缺失：撤销入口禁用")
        XCTAssertThrowsError(try engine.undo()) { error in
            guard case RestoreEngineError.undoSnapshotMissing = error else {
                return XCTFail("应抛 undoSnapshotMissing，实际 \(error)")
            }
        }
        XCTAssertTrue(world.bridge.moves.isEmpty, "入口禁用不得动手")
        XCTAssertTrue(world.geometry.calls.isEmpty, "入口禁用不得动手")
        XCTAssertTrue(world.log.all.contains { $0.contains("[undo]") && $0.contains("undo-snapshot-missing") },
                      "应有明确 abort 日志，实际：\(world.log.all)")
    }

    func testUndoWithCorruptUndoFileIsDisabledAndQuarantined() throws {
        let world = makeWorld()
        let url = undoURL(world.store)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not-json{{".utf8).write(to: url)

        let engine = makeEngine(world)
        XCTAssertFalse(engine.canUndo(), "回滚快照损坏：撤销入口禁用")
        XCTAssertThrowsError(try engine.undo()) { error in
            guard case RestoreEngineError.undoSnapshotCorrupt = error else {
                return XCTFail("应抛 undoSnapshotCorrupt，实际 \(error)")
            }
        }
        // §7.4 损坏隔离：改名 .corrupt-<时间戳> 挪开，原路径腾空（下次恢复重写）
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "损坏文件应已挪开")
        let dirContents = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertTrue(dirContents.contains { $0.hasPrefix("undo-\(url.lastPathComponent.dropFirst(5)).corrupt-") }
                     || dirContents.contains { $0.hasPrefix("\(url.lastPathComponent).corrupt-") },
                     "应按 §7.4 改名隔离，实际：\(dirContents)")
        XCTAssertTrue(world.bridge.moves.isEmpty, "入口禁用不得动手")
        XCTAssertTrue(world.geometry.calls.isEmpty, "入口禁用不得动手")
    }

    // MARK: A18 — 无全屏恢复后撤销：几何/Space/屏幕一步回滚 + 回滚快照保留 + verify 核回滚

    func testUndoAfterRestoreRollsBackGeometrySpaceDisplayInOneStep() throws {
        let world = makeWorld()
        let engine = makeEngine(world)
        let url = undoURL(world.store)

        // 第一步：恢复到 S（101 被折腾到 B#1 (0.5,0.5,0.3,0.3)），回滚快照同时落盘
        XCTAssertFalse(engine.canUndo(), "恢复前尚无回滚快照，撤销入口禁用")
        let restoreReport = try engine.restore(snapshot: world.snapshot)
        XCTAssertEqual(restoreReport.okCount, 1)
        XCTAssertEqual(world.bridge.byWindow[101], 6, "恢复应把 101 桥接到 B#1")
        XCTAssertTrue(engine.canUndo(), "恢复后回滚快照已落盘，撤销入口可用")

        // 实况推进到恢复后：101 在 B 屏 (0.5,0.5,0.3,0.3)（FakeBridge.byWindow 已随 moves 变更）
        let postRestoreSamples = [
            World.sample(wid: 101, bundleID: "com.t.a", title: "Doc",
                         displayOrigin: bOrigin, displaySize: screenSize, x: 0.5, y: 0.5, w: 0.3, h: 0.3),
            World.sample(wid: 202, bundleID: "com.t.other", title: "Extra",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.55, y: 0.55, w: 0.3, h: 0.3),
        ]

        // 第二步：撤销 → 读 undo-<拓扑键>.json 整体回滚到 U
        let undo = try makeEngine(world, samples: postRestoreSamples).undo()

        // 一步回滚：Space（6→5）+ 屏幕（B→A）+ 几何（U 比例 × A bounds）
        XCTAssertEqual(world.bridge.byWindow[101], 5, "撤销应把 101 桥接回 A#1")
        XCTAssertTrue(world.geometry.calls.contains(FakeGeometry.Call(
            windowID: 101, position: CGPoint(x: 100, y: 100), size: CGSize(width: 400, height: 400))),
            "撤销应按 U 几何摆位，实际 \(world.geometry.calls)")

        // 计数：U 两条目（101/202）全 ok；无全屏待办、无失败、不产出两段式文案
        XCTAssertEqual(undo.okCount, 2)
        XCTAssertEqual(undo.failCount, 0)
        XCTAssertEqual(undo.fullscreenPendingCount, 0)
        XCTAssertFalse(undo.isTwoStageFirstPass)
        XCTAssertNil(undo.twoStageNotificationText, "无全屏待办不产出两段式文案")
        XCTAssertEqual(undo.undoSnapshotURL, url)

        // §7.4：撤销后 undo 文件保留（重复撤销幂等无害，至下次恢复才被覆盖）
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "撤销后回滚快照必须保留")
        let preserved = try Snapshot.decode(from: Data(contentsOf: url))
        XCTAssertEqual(preserved.windows.count, 2, "保留的回滚快照内容不变（恢复前实况 101+202）")

        // 验收「撤销后 verify 可核回滚结果」：按 fakes 终态重算实况，与保留的回滚快照全量比对
        // 几何 = 写接缝调用逐次应用后的绝对 bounds（restore 与 undo 的写按序覆盖，终态 = undo 写）；
        // Space = FakeBridge.byWindow 终态；屏幕 = bounds 中心点归属（与引擎同口径）
        var boundsByWID: [UInt32: CGRect] = [:]
        for call in world.geometry.calls {
            boundsByWID[call.windowID] = CGRect(origin: call.position, size: call.size)
        }
        let liveWindows: [LiveWindow] = postRestoreSamples.map { sample in
            let bounds = boundsByWID[sample.windowID] ?? sample.bounds
            return LiveWindow(cgWindowID: sample.windowID, bundleID: sample.bundleID,
                              title: sample.title ?? "",
                              x: Double(bounds.minX - aOrigin.x) / Double(screenSize.width),
                              y: Double(bounds.minY - aOrigin.y) / Double(screenSize.height),
                              w: Double(bounds.width) / Double(screenSize.width),
                              h: Double(bounds.height) / Double(screenSize.height),
                              minimized: false)
        }
        func displayUUID(of bounds: CGRect) -> String {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            return center.x < 1000 ? "A-uuid" : "B-uuid"
        }
        var displayByWID: [UInt32: String] = [:]
        var spaceByWID: [UInt32: SpaceEntry] = [:]
        for sample in postRestoreSamples {
            let bounds = boundsByWID[sample.windowID] ?? sample.bounds
            displayByWID[sample.windowID] = displayUUID(of: bounds)
            spaceByWID[sample.windowID] = World.entry("A-uuid", index: 1, id: world.bridge.byWindow[sample.windowID] ?? 5)
        }
        let results = VerifyComparer.compare(snapshot: preserved, liveWindows: liveWindows,
                                             displayUUIDByWindowID: displayByWID,
                                             spaceEntryByWindowID: spaceByWID)
        XCTAssertEqual(results.count, 2)
        for result in results {
            XCTAssertEqual(result.verdict, .pass, "撤销后 verify 应全 PASS：\(result)")
        }
    }

    // MARK: A19 第一段 — 含全屏恢复后撤销：跳过全屏 + §8.6 文案逐字（N 计数）

    /// A19 世界：U 实况 = 101(A#1) + 202(A#1) + 301(com.t.fs 全屏，A#2 fullscreen Space id7)；
    /// S 恢复目标 = 101→A#1（原位）+ fullscreen Space B#2 携带 com.t.fs（恢复把 301 全屏到 B 屏）。
    /// U 的 windows 不含 301（schema §7.3 全屏应用由 fullscreen Space 携带，不进 windows）。
    func makeFullscreenWorld() -> UndoWorld {
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [
                World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000),
                World.topologyEntry(uuid: "B-uuid", name: "B", orientation: 0, x: 2000, y: 0, w: 1000, h: 1000),
            ],
            spaces: [
                World.userSpace("A-uuid", index: 1),
                World.userSpace("B-uuid", index: 1),
                SnapshotSpace(displayUUID: "B-uuid", index: 2, kind: .fullscreen, fullscreenAppBundleID: "com.t.fs"),
            ],
            windows: [World.snapshotWindow(bundleID: "com.t.a", title: "Doc", sibling: 0,
                                           display: "A-uuid", space: 1, x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        let initialSamples = [
            World.sample(wid: 101, bundleID: "com.t.a", title: "Doc",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
            World.sample(wid: 202, bundleID: "com.t.other", title: "Extra",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.55, y: 0.55, w: 0.3, h: 0.3),
            // 301 = com.t.fs 全屏窗在 A 屏：整屏 bounds + 离屏（后台全屏 Space，§5.2）
            CGWindowSample(windowID: 301, pid: 300, bundleID: "com.t.fs", title: "Full",
                           bounds: CGRect(origin: aOrigin, size: screenSize), isOnscreen: false),
        ]
        return UndoWorld(
            snapshot: snapshot,
            initialSamples: initialSamples,
            ax: UndoFakeAX(fullScreenIDs: [301]),
            bridge: FakeBridge(
                entries: [
                    World.entry("A-uuid", index: 1, id: 5),
                    World.entry("A-uuid", index: 2, id: 7, kind: 4),  // 全屏 Space（spec §5.1 kind=4）
                    World.entry("B-uuid", index: 1, id: 6),
                ],
                byWindow: [101: 5, 202: 5, 301: 7]),
            geometry: FakeGeometry(),
            fullscreen: FakeFullScreen(),
            log: LogSpy(),
            store: SnapshotStore(directory: try! makeTempDir()))
    }

    /// A19 第一段：恢复把 301 全屏到 B 屏后撤销——301 卡在后台全屏 Space 不可达（§5.2），
    /// 第一段跳过（不写 AXFullScreen、不桥接）并计 pending，文案逐字 §8.6；其余窗口照常回滚。
    func testUndoFirstPassSkipsStuckFullscreenAppAndReportsExactText() throws {
        let world = makeFullscreenWorld()
        try makeEngine(world).restore(snapshot: world.snapshot)
        // 恢复后实况：301 全屏在 B 屏新建 fullscreen Space（id8），A#2(id7) 随应用离开销毁
        world.bridge.entries = [
            World.entry("A-uuid", index: 1, id: 5),
            World.entry("B-uuid", index: 1, id: 6),
            World.entry("B-uuid", index: 2, id: 8, kind: 4),
        ]
        world.bridge.byWindow[301] = 8
        let postRestoreSamples = [
            World.sample(wid: 101, bundleID: "com.t.a", title: "Doc",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
            World.sample(wid: 202, bundleID: "com.t.other", title: "Extra",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.55, y: 0.55, w: 0.3, h: 0.3),
            CGWindowSample(windowID: 301, pid: 300, bundleID: "com.t.fs", title: "Full",
                           bounds: CGRect(origin: bOrigin, size: screenSize), isOnscreen: false),
        ]
        let movesBefore = world.bridge.moves.count
        let fsCallsBefore = world.fullscreen.calls.count

        let undo = try makeEngine(world, samples: postRestoreSamples).undo()

        // 第一段不碰全屏：无新 AXFullScreen 写（尤其不得尝试 false——后台退出不可达 §5.2）、301 不桥接
        XCTAssertEqual(world.fullscreen.calls.count, fsCallsBefore, "第一段不得写全屏状态，实际：\(world.fullscreen.calls)")
        let undoMoves = world.bridge.moves.dropFirst(movesBefore).flatMap(\.wids)
        XCTAssertFalse(undoMoves.contains(301), "卡在全屏的窗口第一段不得桥接，实际：\(undoMoves)")
        XCTAssertEqual(undoMoves, [101, 202], "其余常规窗照常回滚")

        // 计数与文案：N=1，§8.6 逐字；待办计 skip（不灭失败）
        XCTAssertEqual(undo.fullscreenPendingCount, 1)
        XCTAssertTrue(undo.isTwoStageFirstPass)
        XCTAssertEqual(undo.twoStageNotificationText,
                       "撤销完成。1 个全屏应用无法在后台退出全屏：请在对应屏幕按 Esc 退出全屏，"
                       + "然后再次点击「撤销上次恢复」完成剩余归位。")
        XCTAssertEqual(undo.okCount, 2)
        XCTAssertEqual(undo.skipCount, 1)
        XCTAssertEqual(undo.failCount, 0)
        XCTAssertTrue(world.log.all.contains {
            $0.contains("reason=fullscreen-exit-pending") && $0.contains("app=com.t.fs") },
            "应有 pending skip 日志，实际：\(world.log.all)")

        // 回滚快照保留（第二段还要用，§7.4）
        let url = undoURL(world.store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let preserved = try Snapshot.decode(from: Data(contentsOf: url))
        XCTAssertTrue(preserved.spaces.contains {
            $0.kind == .fullscreen && $0.fullscreenAppBundleID == "com.t.fs" },
            "保留的回滚快照仍携带全屏 Space 条目")
    }

    /// 撤销时「恢复前是常规窗、恢复被打成全屏」的窗口（U.windows 有条目）：第一段同样跳过计 pending，
    /// 不桥接不写几何（桥接全屏窗 no-op 会毒化 L2 运行时标记，§5.2）
    func testUndoFirstPassSkipsWindowPromotedToFullscreenByRestore() throws {
        // U：401(com.t.x) 常规窗 A#1；S：fullscreen Space A#2 携带 com.t.x（恢复把 401 全屏到 A 屏）
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [
                World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000),
                World.topologyEntry(uuid: "B-uuid", name: "B", orientation: 0, x: 2000, y: 0, w: 1000, h: 1000),
            ],
            spaces: [
                World.userSpace("A-uuid", index: 1),
                World.userSpace("B-uuid", index: 1),
                SnapshotSpace(displayUUID: "A-uuid", index: 2, kind: .fullscreen, fullscreenAppBundleID: "com.t.x"),
            ],
            windows: [])
        let initialSamples = [
            World.sample(wid: 401, bundleID: "com.t.x", title: "X",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.1, y: 0.1, w: 0.2, h: 0.2),
            World.sample(wid: 202, bundleID: "com.t.other", title: "Extra",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.55, y: 0.55, w: 0.3, h: 0.3),
        ]
        let bridge = FakeBridge(
            entries: [World.entry("A-uuid", index: 1, id: 5), World.entry("B-uuid", index: 1, id: 6)],
            byWindow: [401: 5, 202: 5])
        let geometry = FakeGeometry(), fullscreen = FakeFullScreen(), log = LogSpy()
        let store = SnapshotStore(directory: try! makeTempDir())
        func make(samples: [CGWindowSample]) -> RestoreEngine {
            RestoreEngine(store: store, spaces: bridge, enumerator: MutableEnumerator(samples),
                          ax: UndoFakeAX(), geometry: geometry, fullscreen: fullscreen,
                          minimize: FakeMinimize(), fullscreenSettleSeconds: 0,
                          displaysProvider: { World.displays() },
                          rotationProvider: World.rotationProvider([1: 0, 2: 0]), log: log)
        }

        // 恢复：401 被打成全屏（已在目标屏免预移位）
        try make(samples: initialSamples).restore(snapshot: snapshot)
        bridge.entries = [
            World.entry("A-uuid", index: 1, id: 5),
            World.entry("A-uuid", index: 2, id: 8, kind: 4),
            World.entry("B-uuid", index: 1, id: 6),
        ]
        bridge.byWindow[401] = 8
        let postRestoreSamples = [
            CGWindowSample(windowID: 401, pid: 400, bundleID: "com.t.x", title: "X",
                           bounds: CGRect(origin: aOrigin, size: screenSize), isOnscreen: false),
            World.sample(wid: 202, bundleID: "com.t.other", title: "Extra",
                         displayOrigin: aOrigin, displaySize: screenSize, x: 0.55, y: 0.55, w: 0.3, h: 0.3),
        ]
        let movesBefore = bridge.moves.count
        let geometryBefore = geometry.calls.count

        let undo = try make(samples: postRestoreSamples).undo()

        // 第一段：401 卡在全屏 Space → pending，不桥接不写几何
        let undoMoves = bridge.moves.dropFirst(movesBefore).flatMap(\.wids)
        XCTAssertFalse(undoMoves.contains(401), "第一段不得桥接全屏窗，实际：\(undoMoves)")
        let undoGeometry = geometry.calls.dropFirst(geometryBefore).map(\.windowID)
        XCTAssertFalse(undoGeometry.contains(401), "第一段不得写全屏窗几何，实际：\(undoGeometry)")
        XCTAssertEqual(undoGeometry, [202], "仅常规窗照常回滚几何")
        XCTAssertEqual(undo.fullscreenPendingCount, 1)
        XCTAssertNotNil(undo.twoStageNotificationText)
        XCTAssertEqual(undo.failCount, 0)
    }
}
