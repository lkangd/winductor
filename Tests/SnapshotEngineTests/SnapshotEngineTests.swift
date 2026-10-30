import AppKit
import Core
import Foundation
import XCTest
@testable import SnapshotEngine

// SnapshotEngineTests — 引擎层验收（spec §7.5，票面逐项）：
//   无变化不写盘、有变化落盘、未就绪零落盘、轮询环零 AX、防抖合并、1+4 滚动。
// 接缝：SnapshotEngine（pollNow / writePendingNow / readinessGate）+ 注入 fake 枚举/AX/Spaces。
final class SnapshotEngineTests: XCTestCase {
    private var root: URL!
    private var log: LogSpy!

    override func setUpWithError() throws {
        root = try makeTempDir()
        log = LogSpy()
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
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

    /// 每拓扑恰好 1+4 份：live + history-1..4，最旧被淘汰（第 6 次写后 history-4 = 第 2 次内容）。
    /// 采样序列成对给（poll 一次 + 写盘取新采样一次）：写入序列恰为 w1..w6。
    func testRollingHistoryKeepsExactlyOneLivePlusFourSlots() throws {
        var samples: [[CGWindowSample]] = [[]]
        for n in 1...6 {
            let s = sample(id: UInt32(n), bundleID: "com.a", title: "w\(n)")
            samples += [[s], [s]]
        }
        let engine = makeEngine(FakeEnumerator(samples))
        for _ in 0..<6 {
            engine.pollNow()
            engine.writePendingNow()
        }
        let key = topologyKey()
        XCTAssertEqual(try snapshotFiles().count, 5, "恰好 1+4 份")
        for slot in 1...4 {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: root.appendingPathComponent("history-\(slot)-\(key).json").path))
        }
        let oldest = try Snapshot.decode(from: Data(contentsOf:
            root.appendingPathComponent("history-4-\(key).json")))
        XCTAssertEqual(oldest.windows.map(\.title), ["w2"], "最旧（w1）已被淘汰")
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

    private func makeEngine(_ enumerator: FakeEnumerator, ax: WindowAXProbing = FakeAXProber(),
                            pollInterval: TimeInterval = 3600, debounceInterval: TimeInterval = 3600,
                            notificationCenters: [NotificationCenter]? = nil) -> SnapshotEngine {
        let display = fakeDisplay("AAAA-1111-1111-1111-111111111111")
        return SnapshotEngine(
            store: SnapshotStore(directory: root, log: log),
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
            notificationCenters: notificationCenters ?? [NotificationCenter()])
    }

    private func sample(id: UInt32, bundleID: String, title: String,
                        onscreen: Bool = true) -> CGWindowSample {
        CGWindowSample(windowID: id, pid: 42, bundleID: bundleID, title: title,
                       bounds: CGRect(x: 100, y: 100, width: 400, height: 300),
                       isOnscreen: onscreen)
    }

    private func topologyKey() -> String {
        SnapshotStore.topologyKey(forDisplayUUIDs: ["AAAA-1111-1111-1111-111111111111"])
    }

    private func snapshotFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("live-") || $0.hasPrefix("history-") }
    }

    private func decodeLive() throws -> Snapshot {
        try Snapshot.decode(from: Data(contentsOf: root.appendingPathComponent("live-\(topologyKey()).json")))
    }

    private func writeCount() -> Int {
        log.all.filter { $0.contains("action=write") && $0.contains("result=ok") }.count
    }
}
