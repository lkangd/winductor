@testable import Core
import RestoreEngine
import SpaceAdapter
import XCTest

// display-presets 票 12：Space 落位按同屏用户桌面序号、实况全屏窗不桥接、桥接 no-op 失效标记限本轮。
// 场景来自功能验收4（单屏期间重排 Space 后回三屏，WeChat/cmux 落到错的 Space）。

extension RestorePipelineTests {
    static func fullscreenSpace(_ displayUUID: String, index: Int, app: String) -> SnapshotSpace {
        SnapshotSpace(displayUUID: displayUUID, index: index, kind: .fullscreen, fullscreenAppBundleID: app)
    }

    /// 单屏 A：快照 [u,u,FS,FS]、实况 [u,FS,FS,u]（用户在单屏期间把全屏 Space 挪到前面）
    func reorderedFullscreenWorld() -> (snapshot: Snapshot, bridge: FakeBridge) {
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000)],
            spaces: [World.userSpace("A-uuid", index: 1), World.userSpace("A-uuid", index: 2),
                     Self.fullscreenSpace("A-uuid", index: 3, app: "com.t.fs1"),
                     Self.fullscreenSpace("A-uuid", index: 4, app: "com.t.fs2")],
            windows: [World.snapshotWindow(bundleID: "com.t.chat", title: "Chat", sibling: 0,
                                           display: "A-uuid", space: 2, x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        let bridge = FakeBridge(
            entries: [World.entry("A-uuid", index: 1, id: 11),
                      World.entry("A-uuid", index: 2, id: 12, kind: SpaceKind.fullscreen),
                      World.entry("A-uuid", index: 3, id: 13, kind: SpaceKind.fullscreen),
                      World.entry("A-uuid", index: 4, id: 14)],
            byWindow: [101: 11])
        return (snapshot, bridge)
    }

    func testSnapshotSecondDesktopTargetsLiveSecondUserDesktopNotSameIndexFullscreen() throws {
        let world = reorderedFullscreenWorld()
        let samples = [World.sample(wid: 101, bundleID: "com.t.chat", title: "Chat",
                                    displayOrigin: aOrigin, displaySize: screenSize, x: 0.1, y: 0.1, w: 0.4, h: 0.4)]
        let log = LogSpy()
        let engine = singleDisplayEngine(snapshot: world.snapshot, samples: samples,
                                         bridge: world.bridge, geometry: FakeGeometry(), log: log)

        try engine.restore(snapshot: world.snapshot)

        // 快照 #2 = 第 2 个用户桌面 → 实况第 2 个用户桌面 #4（id14），而非同 index 的全屏 Space #2
        XCTAssertEqual(world.bridge.moves.map(\.spaceID), [14])
        XCTAssertFalse(log.all.contains { $0.contains("space-merge") }, "用户桌面数相同，不属合并")
    }

    func testUserDesktopShortageMergesIntoLastLiveUserDesktopNeverFullscreen() throws {
        // 快照 [u,u,u] 窗在 #3；实况 [u,FS]：只剩 1 个用户桌面 → 并入 #1 并记合并，全屏 #2 不作目标
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000)],
            spaces: [World.userSpace("A-uuid", index: 1), World.userSpace("A-uuid", index: 2),
                     World.userSpace("A-uuid", index: 3)],
            windows: [World.snapshotWindow(bundleID: "com.t.chat", title: "Chat", sibling: 0,
                                           display: "A-uuid", space: 3, x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        let bridge = FakeBridge(
            entries: [World.entry("A-uuid", index: 1, id: 11),
                      World.entry("A-uuid", index: 2, id: 12, kind: SpaceKind.fullscreen)],
            byWindow: [101: 11])
        let samples = [World.sample(wid: 101, bundleID: "com.t.chat", title: "Chat",
                                    displayOrigin: aOrigin, displaySize: screenSize, x: 0.1, y: 0.1, w: 0.4, h: 0.4)]
        let log = LogSpy()
        let engine = singleDisplayEngine(snapshot: snapshot, samples: samples,
                                         bridge: bridge, geometry: FakeGeometry(), log: log)

        try engine.restore(snapshot: snapshot)

        XCTAssertEqual(bridge.moves.map(\.spaceID), [11])
        XCTAssertTrue(log.all.contains { $0.contains("space-merge") && $0.contains("snapshotIndex=3 mergedTo=1") },
                      "应记 space-merge 行，实际：\(log.all)")
    }

    func testLiveWindowInFullscreenSpaceIsSkippedWithoutBridgeOrGeometry() throws {
        // 快照记普通窗（A#1），实况窗却在全屏 Space：桥接对它 no-op、几何写无效 → 整项 skip
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000)],
            spaces: [World.userSpace("A-uuid", index: 1)],
            windows: [World.snapshotWindow(bundleID: "com.t.notes", title: "Notes", sibling: 0,
                                           display: "A-uuid", space: 1, x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        let bridge = FakeBridge(
            entries: [World.entry("A-uuid", index: 1, id: 11),
                      World.entry("A-uuid", index: 2, id: 12, kind: SpaceKind.fullscreen)],
            byWindow: [101: 12])
        let samples = [World.sample(wid: 101, bundleID: "com.t.notes", title: "Notes",
                                    displayOrigin: aOrigin, displaySize: screenSize, x: 0, y: 0, w: 1, h: 1)]
        let geometry = FakeGeometry()
        let log = LogSpy()
        let engine = singleDisplayEngine(snapshot: snapshot, samples: samples,
                                         bridge: bridge, geometry: geometry, log: log)

        let report = try engine.restore(snapshot: snapshot)

        XCTAssertTrue(bridge.moves.isEmpty, "实况全屏窗不得桥接")
        XCTAssertTrue(geometry.calls.isEmpty, "实况全屏窗不得写几何")
        XCTAssertEqual(report.skipCount, 1)
        XCTAssertEqual(report.okCount, 0)
        XCTAssertEqual(report.failCount, 0)
        XCTAssertTrue(log.all.contains { $0.contains("wid=101") && $0.contains("reason=live-fullscreen") },
                      "应记 skip 行 reason=live-fullscreen，实际：\(log.all)")
    }

    func testBridgeNoOpSkipsRestOfRoundButNextRoundBridgesAgain() throws {
        // 两窗都在 B#1、快照在 A#1：第 1 次桥接 no-op → 本轮第 2 窗不再碰桥；下一轮桥接重新可用
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
        bridge.moveReturnsFalse = true
        let engine = RestoreEngine(
            store: PresetStore(directory: try makeTempDir()),
            spaces: bridge, enumerator: FakeEnumerator(samples), ax: FakeAX(),
            geometry: FakeGeometry(), displaysProvider: { World.displays() },
            rotationProvider: World.rotationProvider([1: 0, 2: 0]), log: LogSpy())

        try engine.restore(snapshot: snapshot)
        XCTAssertEqual(bridge.moves.count, 1, "本轮 no-op 后余项快速跳过")

        bridge.moveReturnsFalse = false
        try engine.restore(snapshot: snapshot)
        XCTAssertEqual(bridge.moves.count, 3, "新一轮两窗都重新桥接")
    }

    func testFullscreenPreMoveLandsOnUserDesktopNotAnotherAppsFullscreenSpace() throws {
        // L3 预移位：B 屏实况 [其他应用全屏 #1, 桌面 #2] → 落位桌面 #2（id7），不落到别人的全屏 Space
        let world = makeFullscreenWorld()
        world.bridge.entries = [World.entry("A-uuid", index: 1, id: 5),
                                World.entry("B-uuid", index: 1, id: 6, kind: SpaceKind.fullscreen),
                                World.entry("B-uuid", index: 2, id: 7)]
        world.bridge.byWindow[101] = 7

        _ = try world.engine.restore(snapshot: world.snapshot)

        XCTAssertEqual(world.bridge.moves.last?.wids, [202])
        XCTAssertEqual(world.bridge.moves.last?.spaceID, 7)
    }
}
