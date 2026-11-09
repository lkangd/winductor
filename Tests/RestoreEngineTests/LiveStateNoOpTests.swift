@testable import Core
import RestoreEngine
import SnapshotEngine
import XCTest

// display-presets 票 17：L3 全屏 / L4 最小化按实况判「已就位 / 不可达」，不再空打桥接与 AX。
// 实测（11-09 一屏→三屏）：已在全屏 Space 的窗仍去桥接 → no-op 标记本轮桥接失效 → L4 最小化窗
// 全走「取消最小化 → 桥接 → 重新最小化」回退，可见闪烁；已在目标 Space 的最小化窗本无需动作。

extension RestorePipelineTests {
    /// makeFullscreenWorld 的变体：202（com.t.fs）实况已在某屏的全屏 Space（kind=4）。
    /// onDisplay = 该全屏 Space 所在屏（快照目标屏 = B）
    func makeLiveFullscreenWorld(onDisplay: String) -> (snapshot: Snapshot, bridge: FakeBridge,
                                                        geometry: FakeGeometry, fs: FakeFullScreen,
                                                        log: LogSpy, engine: RestoreEngine) {
        let world = makeFullscreenWorld()
        world.bridge.entries.append(World.entry(onDisplay, index: 2, id: 8, kind: SpaceKind.fullscreen))
        world.bridge.byWindow[202] = 8
        return world
    }

    func testFullscreenAlreadyOnTargetDisplayIsOkWithoutAXOrBridge() throws {
        let world = makeLiveFullscreenWorld(onDisplay: "B-uuid")
        let report = try world.engine.restore(snapshot: world.snapshot)

        XCTAssertTrue(world.fs.calls.isEmpty, "已在目标屏全屏：不写 AXFullScreen（后台窗 AX 不可见必 elementInvalid）")
        XCTAssertFalse(world.bridge.moves.flatMap(\.wids).contains(202), "不桥接全屏窗")
        let l3 = try XCTUnwrap(world.log.all.first { $0.contains("[restore] L3") && $0.contains("wid=202") })
        XCTAssertTrue(l3.contains("result=ok") && l3.contains("before=fullscreen=true"), "实际：\(l3)")
        XCTAssertEqual(report.okCount, 2, "常规窗 101 + 全屏 Space 已就位")
        XCTAssertEqual(report.skipCount, 0)
        XCTAssertEqual(report.failCount, 0)
    }

    func testFullscreenOnOtherDisplaySkipsWithoutBridgeOrAX() throws {
        // 实测：Notion 已在内置屏全屏 Space，L3 照样桥接全屏窗 → no-op → 本轮桥接失效连累 L4
        let world = makeLiveFullscreenWorld(onDisplay: "A-uuid")
        let report = try world.engine.restore(snapshot: world.snapshot)

        XCTAssertTrue(world.fs.calls.isEmpty, "不写 AXFullScreen")
        XCTAssertFalse(world.bridge.moves.flatMap(\.wids).contains(202), "不桥接全屏窗（不触发 no-op 标记）")
        XCTAssertTrue(world.bridge.isBridgeAvailable(), "本轮桥接未被标记失效")
        let l3 = try XCTUnwrap(world.log.all.first { $0.contains("[restore] L3") && $0.contains("wid=202") })
        XCTAssertTrue(l3.contains("result=skip") && l3.contains("reason=fullscreen-on-other-display")
                      && l3.contains("before=fullscreen=true disp=A-uuid"), "实际：\(l3)")
        XCTAssertEqual(report.okCount, 1)
        XCTAssertEqual(report.skipCount, 1)
        XCTAssertEqual(report.failCount, 0)
        XCTAssertEqual(report.fullscreenOnOtherDisplayCount, 1)
    }

    func testFullscreenPicksLargestWindowOfAppOverCompanionStrip() throws {
        // 实测：DevUtils/Things 首个同 bundle 窗是 1512×54 / 1512×42 伴生条，选中它去 setFullScreen 必败
        let strip = World.sample(wid: 203, bundleID: "com.t.fs", title: "",
                                 displayOrigin: aOrigin, displaySize: screenSize,
                                 x: 0.0, y: 0.0, w: 1.0, h: 0.05)
        let world = makeFullscreenWorld(leadingSamples: [(strip, 5)])
        _ = try world.engine.restore(snapshot: world.snapshot)

        XCTAssertEqual(world.fs.calls.map(\.windowID), [202], "选面积最大的主窗，不选伴生条")
    }

    func testMinimizedWindowAlreadyInTargetSpaceIsOkWithZeroCalls() throws {
        // 实测：12 个 Chrome 最小化窗本就在目标 Space（before space=3 = 目标 M/1），无需任何动作
        let world = makeMinimizedWorld()
        world.bridge.byWindow[101] = 7
        let report = try world.engine.restore(snapshot: world.snapshot)

        XCTAssertTrue(world.bridge.directMinimizedBatches.isEmpty, "不调直移")
        XCTAssertTrue(world.bridge.moves.isEmpty, "不桥接")
        XCTAssertTrue(world.mini.calls.isEmpty, "不碰 AXMinimized")
        let l4 = try XCTUnwrap(world.log.all.first { $0.contains("[restore] L4") && $0.contains("wid=101") })
        XCTAssertTrue(l4.contains("result=ok"), "实际：\(l4)")
        XCTAssertEqual(report.okCount, 1); XCTAssertEqual(report.skipCount, 0); XCTAssertEqual(report.failCount, 0)
    }

    func testMinimizedWindowSkipsWithoutUnminimizeWhenBridgeUnavailableThisRound() throws {
        // 实测：本轮桥接已被标失效，回退「取消最小化 → 桥接（必抛）→ 重新最小化」= 每窗 ~0.7s 可见闪烁
        let world = makeMinimizedWorld()
        world.bridge.bridgeAvailable = false
        world.bridge.minimizedDirectMoveFails = true
        let report = try world.engine.restore(snapshot: world.snapshot)

        XCTAssertTrue(world.mini.calls.isEmpty, "桥接不可用不得走取消最小化回退")
        XCTAssertTrue(world.bridge.moves.isEmpty)
        XCTAssertTrue(world.bridge.directMinimizedBatches.isEmpty, "桥接不可用也不试直移")
        let l4 = try XCTUnwrap(world.log.all.first { $0.contains("[restore] L4") && $0.contains("wid=101") })
        XCTAssertTrue(l4.contains("result=skip"), "实际：\(l4)")
        XCTAssertEqual(report.okCount, 0); XCTAssertEqual(report.skipCount, 1); XCTAssertEqual(report.failCount, 0)
    }

    func testMinimizedFallbackStopsOnceBridgeTurnsUnavailableMidGroup() throws {
        // 回退途中桥接被标 no-op（本轮失效）：余下的窗直接 skip，不再取消最小化
        let world = makeMultiMinimizedWorld()
        world.bridge.minimizedDirectMoveFails = true
        world.bridge.moveReturnsFalse = true
        let report = try world.engine.restore(snapshot: world.snapshot)

        XCTAssertEqual(world.mini.calls.map(\.value), [false, true], "仅首窗走回退（no-op 后桥接失效）")
        XCTAssertEqual(report.failCount, 1)
        XCTAssertEqual(report.skipCount, 3)
    }
}
