import AppKit
import Core
import Foundation
import XCTest
@testable import SnapshotEngine

// SnapshotEngineTests — 引擎层验收（spec §7.5，票面逐项）：
//   无变化不写盘、有变化写入、未就绪零写入、轮询环零 AX、防抖合并（票 02 起写入内存现势快照，无滚动历史）。
// 接缝：SnapshotEngine（pollNow / writePendingNow / readinessGate）+ 注入 fake 枚举/AX/Spaces。
final class SnapshotEngineTests: XCTestCase {
    private var log: LogSpy!
    private var live: TransitionalLiveSnapshots!

    override func setUpWithError() throws {
        log = LogSpy()
        live = TransitionalLiveSnapshots(log: log)
    }

    // MARK: 周期 1 — 差分与落盘门控

    /// 无变化不写盘；且轮询环零 AX 调用（AX 只允许出现在写盘路径，结构性约束）
    func testNoChangeWritesNothingAndPollPathCallsZeroAX() throws {
        let w = sample(id: 1, bundleID: "com.a", title: "t")
        let ax = FakeAXProber()
        let engine = makeEngine(FakeEnumerator([w], [w], [w]), ax: ax)
        XCTAssertTrue(engine.pollNow(), "首次采样相对空基线 = 变化（排定防抖）")
        XCTAssertFalse(engine.pollNow(), "基线已建立：同采样无变化")
        XCTAssertFalse(engine.pollNow(), "同采样再轮询 = 无变化")
        XCTAssertEqual(ax.callCount, 0, "在屏窗口无 AX 需求：轮询环零 AX")
        XCTAssertEqual(try snapshotFiles().count, 0, "无变化不排定写盘（writePendingNow 仅供手动强制，此处不调用）")
    }

    /// 有变化 → 落盘现势快照；AX 只在写盘路径被调用（离屏候选读 minimized）
    func testChangeWritesLiveSnapshotAndAXOnlyOnWritePath() throws {
        let ax = FakeAXProber(minimizedIDs: [7])
        let offscreen = sample(id: 7, bundleID: "com.a", title: "bg", onscreen: false)
        let engine = makeEngine(FakeEnumerator([], [offscreen], [offscreen]), ax: ax)
        XCTAssertTrue(engine.pollNow(), "从空到有窗 = 变化")
        XCTAssertEqual(ax.callCount, 0, "差分阶段不得碰 AX")
        engine.writePendingNow()
        XCTAssertGreaterThan(ax.callCount, 0, "写盘路径才读 AX（离屏候选 minimized）")
        let live = try decodeLive()
        XCTAssertEqual(live.windows.map(\.title), ["bg"])
        XCTAssertEqual(live.windows.map(\.minimized), [true])
    }

    /// 未就绪门控：照常轮询但零落盘（票 18 接真实权限检查）
    func testNotReadyPollsButNeverWrites() throws {
        let w1 = sample(id: 1, bundleID: "com.a", title: "t")
        let w2 = sample(id: 2, bundleID: "com.a", title: "t2")
        let engine = makeEngine(FakeEnumerator([], [w1], [w1], [w2]))
        engine.readinessGate = { false }
        XCTAssertTrue(engine.pollNow(), "未就绪仍要差分（照常轮询）")
        engine.writePendingNow()
        XCTAssertTrue(engine.pollNow(), "再次变化仍被检出")
        engine.writePendingNow()
        XCTAssertFalse(engine.pollNow(), "同采样无变化")
        XCTAssertEqual(try snapshotFiles().count, 0, "未就绪零落盘")

        // 就绪后下一处变化照常落盘
        engine.readinessGate = { true }
        XCTAssertTrue(engine.pollNow(), "就绪后检出新变化")
        engine.writePendingNow()
        XCTAssertEqual(try snapshotFiles().count, 1)
    }

    // MARK: 周期 3 — 防抖合并与 1+4 滚动

    /// 连续变化合并为一次写入：防抖期内再次变化不得排队第二次写
    func testConsecutiveChangesMergeIntoSingleWrite() throws {
        let engine = makeEngine(FakeEnumerator(
            [],
            [sample(id: 1, bundleID: "com.a", title: "t")],
            [sample(id: 1, bundleID: "com.a", title: "t2")]))
        engine.pollNow()
        engine.pollNow()
        engine.writePendingNow()
        XCTAssertEqual(writeCount(), 1, "防抖期内两次变化合并为一次落盘")
    }

    /// 定时器端到端：start 后自动轮询 → 防抖 → 自动落盘（放宽裕量避免抖动）
    func testStartedEngineWritesAutomatically() throws {
        let engine = makeEngine(FakeEnumerator(
            [],
            [sample(id: 1, bundleID: "com.a", title: "t")]),
            pollInterval: 0.1, debounceInterval: 0.2)
        engine.start()
        defer { engine.stop() }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, try snapshotFiles().count == 0 {
            try Task.checkCancellation()
            usleep(20_000)
        }
        XCTAssertEqual(try snapshotFiles().count, 1, "2s 轮询（测试 0.1s）→ 防抖（测试 0.2s）→ 自动落盘")
    }

    // MARK: 周期 4 — 单次差分毫秒级（对照 04 基线 optionAll ≈6.7ms）

    /// 真实 CGWindowListCopyWindowInfo(.optionAll) 单次差分耗时毫秒级；打印实测值作验收证据
    func testRealDifferentialIsMillisecondLevel() {
        let enumerator = CGWindowListEnumerator()
        _ = enumerator.sample()  // warmup
        var total = 0.0
        let n = 5
        for _ in 0..<n {
            let t0 = DispatchTime.now()
            _ = enumerator.sample()
            total += Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        }
        let avg = total / Double(n)
        print(String(format: "[验收] 单次差分(含 .optionAll 采样+候选过滤) avg = %.2f ms（04 基线 6.7ms）", avg))
        XCTAssertLessThan(avg, 250, "单次差分应毫秒级；250ms 为防 CI 抖动的宽松上限")
    }

    // MARK: 加速器 — 应用启退/屏幕事件立即差分（注入通知中心，fake 驱动）

    /// 注入的 fake 通知中心投递启退/屏幕事件 → 立即差分一次（不等 2s 轮询 timer）
    func testAcceleratorNotificationsTriggerImmediateDifferential() throws {
        let center = NotificationCenter()
        let enumerator = FakeEnumerator(
            [],
            [sample(id: 1, bundleID: "com.a", title: "t1")],
            [sample(id: 1, bundleID: "com.a", title: "t2")])
        let engine = makeEngine(enumerator, notificationCenters: [center])
        engine.start()
        defer { engine.stop() }
        XCTAssertEqual(enumerator.callCount, 1, "start 即差分一次建立基线")
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        XCTAssertEqual(enumerator.callCount, 2, "应用启动加速器：立即差分一次（检出变化）")
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(enumerator.callCount, 3, "屏幕事件加速器：立即差分一次（检出变化）")
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        XCTAssertEqual(enumerator.callCount, 4, "应用退出加速器：立即差分一次（无变化）")
        engine.writePendingNow()
        XCTAssertEqual(try decodeLive().windows.map(\.title), ["t2"], "加速器检出的变化经防抖路径落盘")
    }

    /// stop 后加速器观察已注销：再投递不触发差分
    func testStopRemovesAcceleratorObservers() {
        let center = NotificationCenter()
        let enumerator = FakeEnumerator([])
        let engine = makeEngine(enumerator, notificationCenters: [center])
        engine.start()
        engine.stop()
        let callsAfterStop = enumerator.callCount
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(enumerator.callCount, callsAfterStop, "stop 后不再差分")
    }

    // MARK: 工具

    /// 实测缺陷（11-03 09:08:16）：拔屏开始后，开拔前已在途的写盘按「起点拓扑键」落盘了拔屏中途的
    /// 窗口/Space 态；0.3s 后触发链冻结拔屏前基线读到的正是这份垃圾 → 插回时结构门槛 6 轮不过放弃恢复。
    /// 期望：采样期间显示器集合/几何变了 → 丢弃本次写盘（拓扑键与内容不一致）。
    func testWriteDiscardedWhenTopologyChangesWhileComposing() throws {
        final class Flip: @unchecked Sendable { var calls = 0 }
        let flip = Flip()
        let a = fakeDisplay("AAAA-1111-1111-1111-111111111111")
        let b = fakeDisplay("BBBB-2222-2222-2222-222222222222", x: 1000)
        let w = sample(id: 1, bundleID: "com.a", title: "t")
        let engine = SnapshotEngine(
            store: live,
            spaces: FakeSpaces(entries: [SpaceEntry(spaceID: 11, displayUUID: a.uuid!, index: 1, kind: 0)],
                               byWindow: [1: 11]),
            log: log, enumerator: FakeEnumerator([w], [w]), ax: FakeAXProber(),
            displaysProvider: {
                flip.calls += 1
                return flip.calls == 1 ? [a, b] : [a]  // 写盘起点 2 屏，采样后已拔成 1 屏
            },
            pollInterval: 3600, pollTolerance: 0.5, debounceInterval: 3600,
            notificationCenters: [NotificationCenter()])
        engine.writePendingNow()
        XCTAssertEqual(try snapshotFiles(), [], "拓扑在采样期间变化：不得按旧拓扑键落盘")
        XCTAssertTrue(log.all.contains { $0.contains("detail=topology-changed-while-composing") })
    }

    private func makeEngine(_ enumerator: FakeEnumerator, ax: WindowAXProbing = FakeAXProber(),
                            pollInterval: TimeInterval = 3600, debounceInterval: TimeInterval = 3600,
                            notificationCenters: [NotificationCenter]? = nil,
                            session: SkyLightSession = SkyLightSession(),
                            deferredGeometry: DeferredGeometryPort? = nil) -> SnapshotEngine {
        let display = fakeDisplay("AAAA-1111-1111-1111-111111111111")
        return SnapshotEngine(
            store: live,
            spaces: FakeSpaces(
                entries: [SpaceEntry(spaceID: 11, displayUUID: display.uuid!, index: 1, kind: 0)],
                byWindow: [1: 11, 7: 11]),
            log: log,
            enumerator: enumerator,
            ax: ax,
            displaysProvider: { [display] },
            pollInterval: pollInterval,
            pollTolerance: 0.5,
            debounceInterval: debounceInterval,
            notificationCenters: notificationCenters ?? [NotificationCenter()],
            deferredGeometry: deferredGeometry,
            session: session)
    }

    private func sample(id: UInt32, bundleID: String, title: String,
                        onscreen: Bool = true) -> CGWindowSample {
        CGWindowSample(windowID: id, pid: 42, bundleID: bundleID, title: title,
                       bounds: CGRect(x: 100, y: 100, width: 400, height: 300),
                       isOnscreen: onscreen)
    }

    private func topologyKey() -> String {
        TransitionalLiveSnapshots.topologyKey(forDisplayUUIDs: ["AAAA-1111-1111-1111-111111111111"])
    }

    /// 已写入现势快照的拓扑键（每拓扑至多一份）
    private func snapshotFiles() throws -> [String] {
        live.topologyKeys
    }

    private func decodeLive() throws -> Snapshot {
        try XCTUnwrap(live.loadLive(topologyKey: topologyKey()))
    }

    private func writeCount() -> Int {
        log.all.filter { $0.contains("action=write") && $0.contains("result=ok") }.count
    }
}

// MARK: - 可见性迁移（后台窗延迟几何消费口）

extension SnapshotEngineTests {
    /// 上轮不可见 → 本轮可见的窗口集合交给延迟几何端口；首采样只建基线不触发
    func testNewlyVisibleWindowsReportedToDeferredGeometry() throws {
        let deferred = FakeDeferredGeometry()
        let engine = makeEngine(FakeEnumerator([sample(id: 9, bundleID: "com.t", title: "t", onscreen: false)],
                                               [sample(id: 9, bundleID: "com.t", title: "t", onscreen: true)]),
                                deferredGeometry: deferred)

        _ = engine.pollNow()  // 首采样：建立基线
        XCTAssertEqual(deferred.becameVisible.count, 0, "首采样不触发迁移")
        _ = engine.pollNow()  // off → on
        XCTAssertEqual(deferred.becameVisible, [[9]], "变为可见的窗口集合回调")
    }

    /// 待补写窗写盘按延迟几何目标记录（同屏时；见 SnapshotComposer）
    func testWriteAppliesDeferredGeometryOverrides() throws {
        let deferred = FakeDeferredGeometry()
        deferred.overrides = [1: WindowGeometryOverride(displayUUID: "AAAA-1111-1111-1111-111111111111",
                                                        x: 0.5, y: 0.5, w: 0.25, h: 0.25)]
        let engine = makeEngine(FakeEnumerator([sample(id: 1, bundleID: "com.t", title: "t")]),
                                deferredGeometry: deferred)
        XCTAssertTrue(engine.pollNow())
        engine.writePendingNow()
        let w = try XCTUnwrap(decodeLive().windows.first)
        XCTAssertEqual([w.x, w.y, w.w, w.h], [0.5, 0.5, 0.25, 0.25])
    }
}

extension SnapshotEngineTests {
    /// 恢复管线独占 SkyLight 期间不采样（采样会触发可见性迁移补写，与管线几何写冲突）
    func testPollSkippedWhileSessionExclusive() throws {
        let session = SkyLightSession()
        let fake = FakeEnumerator([sample(id: 1, bundleID: "com.t", title: "t")])
        let engine = makeEngine(fake, session: session)

        session.exclusive("restore") {
            XCTAssertFalse(engine.pollNow(), "独占期间不采样")
        }
        XCTAssertEqual(fake.callCount, 0, "enumerator 未被调用")
        XCTAssertTrue(engine.pollNow(), "独占结束恢复采样")
    }

    /// 防抖写盘撞上管线独占：本次不写（compose 读 SLS 会与管线并发），下一轮 poll 重新检出并写
    func testWriteSkippedDuringExclusiveIsRetriedOnNextPoll() throws {
        let session = SkyLightSession()
        let w = sample(id: 1, bundleID: "com.t", title: "t")
        let engine = makeEngine(FakeEnumerator([w]), session: session)
        XCTAssertTrue(engine.pollNow())

        session.exclusive("restore") { engine.writePendingNow() }
        XCTAssertEqual(try snapshotFiles().count, 0, "独占期间不写盘")

        XCTAssertTrue(engine.pollNow(), "被跳过的写盘：同采样也要重新检出为变化")
        engine.writePendingNow()
        XCTAssertEqual(try decodeLive().windows.map(\.title), ["t"])
    }
}
