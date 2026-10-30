@testable import Core
@testable import RestoreEngine  // @testable：测试需构造 RestoreReport（memberwise init 为 internal）
import CoreGraphics
import Foundation
import SnapshotEngine
import XCTest

// TriggerChainTests — 票 17 触发链状态机（spec §6.2/§6.3，fake 注入单测；真实拔插 E2E 留票 20）。
// 断言口径：[trigger] 结构化日志的 step 序列 + at= 时间戳链（票面「日志时间戳链可证明」）。
// 全部经注入 fake 驱动（时钟/调度器/屏幕源/Space 列表/恢复器），不碰真实 AX/SLS。

// MARK: - fake 注入桩（本文件自含，避免与并行票 16 的 Fakes.swift 互相踩）

/// 虚拟时钟：测试手动推进，触发链日志的 at= 时间戳可精确断言
final class FakeTriggerClock: TriggerClockProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(start: Date) { _now = start }
    /// 虚拟当前时刻（测试推进用；协议入口 now() 转发到这里）
    var current: Date {
        get {
            lock.lock(); defer { lock.unlock() }
            return _now
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _now = newValue
        }
    }
    func set(_ date: Date) { current = date }
    func now() -> Date { current }
}

/// 虚拟调度器：记录挂起回调，测试按虚拟时间逐个触发（防抖重置/稳定性轮次全可控）
final class FakeTriggerScheduler: TriggerChainScheduling, @unchecked Sendable {
    final class Item {
        let fireAt: Date
        let block: @Sendable () -> Void
        init(fireAt: Date, block: @escaping @Sendable () -> Void) {
            self.fireAt = fireAt
            self.block = block
        }
    }
    private let lock = NSLock()
    private let clock: FakeTriggerClock
    private var items: [Item] = []
    private var nextID = 0
    init(clock: FakeTriggerClock) { self.clock = clock }

    func schedule(after: TimeInterval, _ fire: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        items.append(Item(fireAt: clock.now().addingTimeInterval(after), block: fire))
    }

    func cancelScheduled() {
        lock.lock(); defer { lock.unlock() }
        items.removeAll()
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return items.count
    }

    /// 推进虚拟时钟到下一个挂起点并触发；返回是否触发了回调
    @discardableResult
    func step() -> Bool {
        lock.lock()
        guard let first = items.min(by: { $0.fireAt < $1.fireAt }) else {
            lock.unlock()
            return false
        }
        items.removeAll { $0 === first }
        lock.unlock()
        clock.set(first.fireAt)
        first.block()
        return true
    }

    /// 反复 step 直到无挂起回调（触发链走完；上限防死循环）
    func runUntilIdle(maxSteps: Int = 64) {
        for _ in 0..<maxSteps where !step() { break }
    }
}

/// Space 列表 fake：队列式弹出每轮采样（耗尽后重复最后一个）；nil 项模拟「本轮不可用」
final class FakeSpaceLists: SpaceListProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [[String]?]
    private(set) var sampleCount = 0
    init(queue: [[String]?]) { self.queue = queue }
    func spaceList() -> [String]? {
        lock.lock(); defer { lock.unlock() }
        sampleCount += 1
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }
}

/// 恢复器 fake：记录 restore 调用（一次性/幂等断言用），可注入返回报告、抛错与副作用
final class FakeSnapshotRestorer: SnapshotRestoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshots: [Snapshot] = []
    var report: RestoreReport
    var error: Error?
    /// restore 时注入的副作用（如经 degradeCollector 写 [degrade] 行，模拟适配器降级日志）
    var onRestore: (@Sendable () -> Void)?
    init(report: RestoreReport) {
        self.report = report
    }
    var snapshots: [Snapshot] {
        lock.lock(); defer { lock.unlock() }
        return _snapshots
    }
    @discardableResult
    func restore(snapshot: Snapshot) throws -> RestoreReport {
        lock.lock(); defer { lock.unlock() }
        _snapshots.append(snapshot)
        onRestore?()
        if let error { throw error }
        return report
    }
}

/// 通知收集器（票 19 投递接缝的测试侧）
final class NoticeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [RestoreNotice] = []
    var items: [RestoreNotice] {
        lock.lock(); defer { lock.unlock() }
        return _items
    }
    func append(_ notice: RestoreNotice) {
        lock.lock(); defer { lock.unlock() }
        _items.append(notice)
    }
}

/// 屏幕源 fake：测试中改 displays 模拟拔出/插回（触发链只读它的公开输出）
final class DisplayBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _displays: [Displays.Info]
    init(_ displays: [Displays.Info]) { _displays = displays }
    var displays: [Displays.Info] {
        lock.lock(); defer { lock.unlock() }
        return _displays
    }
    func set(_ displays: [Displays.Info]) {
        lock.lock(); defer { lock.unlock() }
        _displays = displays
    }
}

// MARK: - 场景构造

private let displayA = Displays.Info(id: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), uuid: "A-uuid")
private let displayB = Displays.Info(id: 2, bounds: CGRect(x: 2000, y: 0, width: 1000, height: 1000), uuid: "B-uuid")
private let displayC = Displays.Info(id: 3, bounds: CGRect(x: 4000, y: 0, width: 1000, height: 1000), uuid: "C-uuid")

private func makeSnapshot(topology uuids: [String]) -> Snapshot {
    Snapshot(
        capturedAt: Date(timeIntervalSince1970: 0),
        topology: uuids.map { World.topologyEntry(uuid: $0, name: $0, orientation: 0, x: 0, y: 0, w: 1000, h: 1000) },
        spaces: [], windows: [])
}

private func makeStore(topologies: [[String]]) throws -> SnapshotStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wlr-triggerchain-\(UUID().uuidString)")
    let store = SnapshotStore(directory: dir)
    for uuids in topologies {
        try store.write(makeSnapshot(topology: uuids),
                        topologyKey: SnapshotStore.topologyKey(forDisplayUUIDs: uuids))
    }
    return store
}

private func report(ok: Int = 0, skip: Int = 0, fail: Int = 0) -> RestoreReport {
    RestoreReport(okCount: ok, skipCount: skip, failCount: fail,
                  matchedCount: ok, untouchedLiveCount: 0, undoSnapshotURL: nil)
}

/// [trigger] 行的 step= 记号序列（触发链形态断言的独立真值来源：日志文本本身）
private func triggerSteps(_ lines: [String]) -> [String] {
    lines.filter { $0.contains("[trigger]") }.compactMap { line in
        line.split(separator: " ").first(where: { $0.hasPrefix("step=") }).map { String($0.dropFirst(5)) }
    }
}

/// [trigger] 行的 result= 记号序列
private func triggerResults(_ lines: [String]) -> [String] {
    lines.filter { $0.contains("[trigger]") }.compactMap { line in
        line.split(separator: " ").first(where: { $0.hasPrefix("result=") }).map { String($0.dropFirst(7)) }
    }
}

private let chainTimestampFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// [trigger] 行的 at= 时间戳序列（触发链时序可证明的断言来源）
private func triggerTimestamps(_ lines: [String]) -> [Date] {
    lines.filter { $0.contains("[trigger]") }.compactMap { line in
        line.split(separator: " ").first(where: { $0.hasPrefix("at=") })
            .flatMap { chainTimestampFormatter.date(from: String($0.dropFirst(3))) }
    }
}

// MARK: - 周期 1：完整触发链（event → debounce → topology-match → space-stable ×2 → restore）

final class TriggerChainTests: XCTestCase {
    func testFullChainEventToRestoreLogsProvableTimestampChainAndRestoresExactlyOnce() throws {
        // 场景：基线 {A}（拔出态）→ 插回 B → {A,B} 集合变大且与快照精确一致
        // → Space 两轮稳定 → 一次性恢复；[trigger] step 序列 + at 时间戳链可证明
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report(ok: 2, skip: 1, fail: 0))
        let spaces = FakeSpaceLists(queue: [["B-uuid#1#0"], ["B-uuid#1#0"]])
        let notices = NoticeRecorder()
        let store = try makeStore(topologies: [["A-uuid", "B-uuid"]])
        let box = DisplayBox([displayA])
        let chain = TriggerChain(
            store: store, restorer: restorer, spaces: spaces,
            displaysProvider: { box.displays },
            clock: clock, scheduler: scheduler, log: spy, degradeCollector: nil,
            onNotice: { notices.append($0) })

        box.set([displayA, displayB])  // 插回 B
        chain.screenParametersChanged()
        scheduler.runUntilIdle()

        // 一次性恢复：恰好一次，且恢复的是精确匹配快照（{A,B}）
        XCTAssertEqual(restorer.snapshots.count, 1, "单轮 best-effort，无重试循环（spec §6.3）")
        XCTAssertEqual(restorer.snapshots.first.map { $0.topology.map(\.uuid).sorted() }, ["A-uuid", "B-uuid"])

        // 触发链日志：step 序列完整呈现链路（票面「日志时间戳链可证明」）
        let steps = triggerSteps(spy.all)
        XCTAssertEqual(steps, ["baseline", "event", "debounce-settle", "topology-match",
                               "space-stable", "space-stable", "restore-start", "restore-done", "notify"])
        // Space 两轮：round=1 采样、round=2 稳定
        let stableLines = spy.all.filter { $0.contains("step=space-stable") }
        XCTAssertTrue(stableLines[0].contains("round=1"))
        XCTAssertTrue(stableLines[1].contains("round=2"))
        XCTAssertTrue(stableLines[1].contains("result=stable"))
        // 时间戳链单调不减，且防抖/稳定间隔落在日志时间上（1.5s 防抖、0.5s 轮间隔）
        let stamps = triggerTimestamps(spy.all)
        XCTAssertEqual(stamps.count, steps.count)
        for (prev, next) in zip(stamps, stamps.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.timeIntervalSince1970, prev.timeIntervalSince1970)
        }
        XCTAssertEqual(stamps[2].timeIntervalSince(stamps[1]), 1.5, accuracy: 0.001, "防抖静默期 1.5s（§10.3）")
        XCTAssertEqual(stamps[5].timeIntervalSince(stamps[4]), 0.5, accuracy: 0.001, "Space 稳定轮间隔 500ms（§10.3）")

        // 完成通知（§8.5）：计数来自 RestoreReport
        XCTAssertEqual(notices.items, [.completed(RestoreCompletionNotice(
            trigger: .auto, okCount: 2, skipCount: 1, failCount: 0,
            degradedLayerNames: [], failureDetail: nil))])
        // 链走完后状态机回 idle：无残留挂起回调（幂等前提）
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    // MARK: - 周期 2：防抖新事件重置 + 反例零动作（A2/A3/A4）

    func testNewEventDuringDebounceResetsTimer() throws {
        // 场景：拔出事件（A4 形态）后 1.4s 又来一个新事件 → 防抖计时重置，
        // 第一次 settle 不发生；第二次 settle 在新事件后 1.5s（虚拟时间 2.9s）
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report())
        let store = try makeStore(topologies: [["A-uuid", "B-uuid"]])
        let box = DisplayBox([displayA, displayB])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: nil,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil, onNotice: { _ in })

        box.set([displayA])            // 拔出 B
        chain.screenParametersChanged()  // t0
        clock.set(clock.current.addingTimeInterval(1.4))
        chain.screenParametersChanged()  // t0+1.4 新事件：重置防抖计时
        scheduler.step()               // 唯一挂起点 = t0+2.9

        XCTAssertEqual(clock.current.timeIntervalSince(Date(timeIntervalSince1970: 1_000_000)),
                       2.9, accuracy: 0.001, "新事件重置 1.5s 计时（旧计时点 t0+1.5 不再触发）")
        XCTAssertEqual(triggerSteps(spy.all).filter { $0 == "debounce-settle" }.count, 1,
                       "被重置的第一次 settle 不落日志")
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testUnchangedSetZeroActionOnWakeLikeEvent() throws {
        // A2/A3：睡眠唤醒/锁屏解锁/分辨率微调 = 事件到达但集合不变 → 零动作不触发
        let scheduler = FakeTriggerScheduler(clock: FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000)))
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report())
        let store = try makeStore(topologies: [["A-uuid", "B-uuid"]])
        let box = DisplayBox([displayA, displayB])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: nil,
                                 displaysProvider: { box.displays }, clock: FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000)),
                                 scheduler: scheduler, log: spy, degradeCollector: nil, onNotice: { _ in })

        box.set([displayA, displayB])  // 分辨率微调不改 UUID 集合
        chain.screenParametersChanged()
        scheduler.runUntilIdle()

        XCTAssertNil(restorer.snapshots.first, "集合不变零动作，不触发恢复")
        XCTAssertEqual(triggerSteps(spy.all), ["baseline", "event", "debounce-settle"],
                       "链止于 debounce-settle，无 topology-match / restore-start")
        XCTAssertEqual(triggerResults(spy.all).last, "unchanged")
    }

    func testShrunkenSetOnlyUpdatesBaselineThenPlugBackTriggers() throws {
        // A4：拔出（集合变小）只更新基线不干预；随后插回（集合变大且精确匹配）→ 完整链触发
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report(ok: 1, skip: 0, fail: 0))
        let spaces = FakeSpaceLists(queue: [["A-uuid#1#0"], ["A-uuid#1#0"]])
        let store = try makeStore(topologies: [["A-uuid", "B-uuid"]])
        let box = DisplayBox([displayA, displayB])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: spaces,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil, onNotice: { _ in })

        box.set([displayA])            // 拔出
        chain.screenParametersChanged()
        scheduler.runUntilIdle()
        XCTAssertNil(restorer.snapshots.first, "拔出不干预")
        XCTAssertEqual(triggerResults(spy.all).last, "shrank")

        box.set([displayA, displayB])  // 插回 → 集合变大且精确匹配快照
        chain.screenParametersChanged()
        scheduler.runUntilIdle()
        XCTAssertEqual(restorer.snapshots.count, 1, "基线已更新为拔出后集合，插回判「变大」触发")
        XCTAssertTrue(triggerSteps(spy.all).contains("restore-start"))
    }

    // MARK: - 周期 3：部分拓扑不自动恢复 + 提示通知（A5）；Space 抖动重采（连续两轮判据重计）

    func testPartialTopologyNoAutoRestoreButPromptNotice() throws {
        // A5：插回后仍少一屏（集合变大但不精确匹配任何快照）→ 不自动恢复 + 提示通知结构产出
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report())
        let notices = NoticeRecorder()
        let store = try makeStore(topologies: [["A-uuid", "B-uuid"]])
        let box = DisplayBox([displayA])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: nil,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil, onNotice: { notices.append($0) })

        box.set([displayA, displayB, displayC])  // 插回但集合 {A,B,C} ≠ 任何快照集合
        chain.screenParametersChanged()
        scheduler.runUntilIdle()

        XCTAssertNil(restorer.snapshots.first, "部分拓扑不自动恢复（spec §6.2）")
        XCTAssertEqual(notices.items, [.partialTopology(PartialTopologyNotice(currentDisplayCount: 3))],
                       "产出「提示通知」结构（投递归票 19）")
        XCTAssertEqual(triggerSteps(spy.all),
                       ["baseline", "event", "debounce-settle", "topology-match", "notify"],
                       "链止于 topology-match，无 space-stable / restore-start")
        XCTAssertEqual(triggerResults(spy.all).last, "partial")
    }

    func testSpaceInstabilityRestartsConsecutiveRounds() throws {
        // Space 列表两轮间变化 → 连续两轮判据重计（changed），再连续两轮不变才触发恢复
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report(ok: 1, skip: 0, fail: 0))
        let spaces = FakeSpaceLists(queue: [["A-uuid#1#0"], ["A-uuid#2#0"], ["A-uuid#2#0"]])
        let store = try makeStore(topologies: [["A-uuid", "B-uuid"]])
        let box = DisplayBox([displayA])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: spaces,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil, onNotice: { _ in })

        box.set([displayA, displayB])
        chain.screenParametersChanged()
        scheduler.runUntilIdle()

        XCTAssertEqual(restorer.snapshots.count, 1)
        let stableLines = spy.all.filter { $0.contains("step=space-stable") }
        XCTAssertEqual(stableLines.count, 3)
        XCTAssertTrue(stableLines[0].contains("result=sampled"), "第 1 轮采样")
        XCTAssertTrue(stableLines[1].contains("result=changed"), "两轮间变化 → 判据重计")
        XCTAssertTrue(stableLines[2].contains("result=stable"), "重计后连续两轮不变 → 触发")
    }

    // MARK: - 周期 4：完成通知计数 + FORCE_DEGRADED 降级附注；失败通知；无重试幂等

    func testCompletionNoticeCountsAndDegradeAnnotation() throws {
        // 完成通知计数与 RestoreReport 一致；恢复期 [degrade] 行经共用 sink 汇总为附注
        // （生产 FORCE_DEGRADED 路径：适配器把同款降级行写进同一个 collector，票 19 接线同构）
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let collector = DegradeCollectingLog(inner: spy)
        let restorer = FakeSnapshotRestorer(report: report(ok: 3, skip: 1, fail: 1))
        restorer.onRestore = { collector.write(
            "[degrade] layer=L2 reason=probe-miss detail=forced by LAYOUTFIXER_FORCE_DEGRADED=bridge") }
        let spaces = FakeSpaceLists(queue: [["A-uuid#1#0"], ["A-uuid#1#0"]])
        let notices = NoticeRecorder()
        let store = try makeStore(topologies: [["A-uuid", "B-uuid"]])
        let box = DisplayBox([displayA])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: spaces,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: collector, degradeCollector: collector, onNotice: { notices.append($0) })

        box.set([displayA, displayB])
        chain.screenParametersChanged()
        scheduler.runUntilIdle()

        XCTAssertEqual(notices.items, [.completed(RestoreCompletionNotice(
            trigger: .auto, okCount: 3, skipCount: 1, failCount: 1,
            degradedLayerNames: ["Space 归属"], failureDetail: nil))])
        XCTAssertEqual(notices.items.first?.body,
                       "恢复完成：3 窗口归位、1 跳过、1 失败；本次 Space 归属层失效（几何已恢复）",
                       "§8.5 措辞：计数 + 降级附注")
        XCTAssertTrue(collector.drainDegradeLayers().isEmpty, "恢复后附注已汇总消费")
    }

    func testRestoreAbortFailureEmitsFailureNotice() throws {
        // 管线中止（如回滚快照写失败）→ 失败通知（§6.3 结束发一条通知，失败详情进日志）
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report())
        restorer.error = RestoreEngineError.undoSnapshotWriteFailed("disk-full")
        let spaces = FakeSpaceLists(queue: [["A-uuid#1#0"], ["A-uuid#1#0"]])
        let notices = NoticeRecorder()
        let store = try makeStore(topologies: [["A-uuid", "B-uuid"]])
        let box = DisplayBox([displayA])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: spaces,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil, onNotice: { notices.append($0) })

        box.set([displayA, displayB])
        chain.screenParametersChanged()
        scheduler.runUntilIdle()

        XCTAssertEqual(notices.items.first?.title, "恢复失败")
        XCTAssertEqual(notices.items.first?.body, "恢复失败：undoSnapshotWriteFailed(\"disk-full\")")
        XCTAssertTrue(triggerSteps(spy.all).contains("restore-failed"))
        XCTAssertEqual(scheduler.pendingCount, 0, "状态机回 idle，无重试残留")
    }

    func testNoRetryLoopIdempotentAfterCompletion() throws {
        // 单轮后回 idle：同一拓扑再来屏幕事件（如分辨率微调）→ 零动作，不重复触发
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report(ok: 1, skip: 0, fail: 0))
        let spaces = FakeSpaceLists(queue: [["A-uuid#1#0"], ["A-uuid#1#0"]])
        let notices = NoticeRecorder()
        let store = try makeStore(topologies: [["A-uuid", "B-uuid"]])
        let box = DisplayBox([displayA])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: spaces,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil, onNotice: { notices.append($0) })

        box.set([displayA, displayB])
        chain.screenParametersChanged()
        scheduler.runUntilIdle()
        XCTAssertEqual(restorer.snapshots.count, 1)

        box.set([displayA, displayB])  // 同集合再来事件（睡眠唤醒等价形态）
        chain.screenParametersChanged()
        scheduler.runUntilIdle()

        XCTAssertEqual(restorer.snapshots.count, 1, "无自动重试循环：单轮后不重复触发（幂等）")
        XCTAssertEqual(notices.items.count, 1)
        XCTAssertEqual(triggerResults(spy.all).last, "unchanged")
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testDegradeCollectorParsesLayerAndForwardsAllLines() throws {
        // [degrade] 行解析：只抽 layer=L<n>；非降级行原样转发；drain 取后清空
        let spy = LogSpy()
        let collector = DegradeCollectingLog(inner: spy)
        collector.write("[trigger] step=event at=x detail=y")
        collector.write("[degrade] layer=L3 reason=probe-miss detail=forced")
        collector.write("[degrade] layer=L12 reason=no-op detail=x")
        XCTAssertEqual(collector.drainDegradeLayers(), [3, 12])
        XCTAssertEqual(collector.drainDegradeLayers(), [], "取后清空")
        XCTAssertEqual(spy.all.count, 3, "全部行原样转发内层 sink")
        XCTAssertNil(DegradeCollectingLog.degradeLayer(in: "[restore] L1 wid=1"))
    }

    // MARK: - 周期 5：手动「立即恢复」（A6，跳过方向判定，与自动触发共用管线）

    func testRestoreNowManualSkipsDirectionJudgment() throws {
        // 无屏幕事件、无变大方向判定：直接恢复当前拓扑匹配快照（spec §6.2/03 #8）
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report(ok: 2, skip: 0, fail: 0))
        let spaces = FakeSpaceLists(queue: [])
        let notices = NoticeRecorder()
        let store = try makeStore(topologies: [["A-uuid", "B-uuid"]])
        let box = DisplayBox([displayA, displayB])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: spaces,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil, onNotice: { notices.append($0) })

        let notice = chain.restoreNow()

        XCTAssertEqual(restorer.snapshots.count, 1)
        XCTAssertEqual(restorer.snapshots.first.map { $0.topology.map(\.uuid).sorted() }, ["A-uuid", "B-uuid"])
        XCTAssertEqual(notice, .completed(RestoreCompletionNotice(
            trigger: .manual, okCount: 2, skipCount: 0, failCount: 0,
            degradedLayerNames: [], failureDetail: nil)))
        XCTAssertEqual(notices.items.first?.trigger, .manual)
        let steps = triggerSteps(spy.all)
        XCTAssertFalse(steps.contains("event"), "手动入口不经屏幕事件/方向判定")
        XCTAssertFalse(steps.contains("debounce-settle"))
        XCTAssertTrue(steps.contains("restore-start"), "与自动触发共用同一恢复管线")
    }

    func testRestoreNowOnPartialTopologyRestoresBestEffortSupersetSnapshot() throws {
        // A6 部分拓扑形态：当前 {A,B}、只有 {A,B,C} 快照 → 选重叠最多的超集快照 best-effort 恢复
        //（缺失屏条目由引擎 target-display-absent skip，即「单屏 best-effort」语义）
        // UUID 用真实形态（36 字符含内连字符）：拓扑键反拆依赖段长恒定（SnapshotStore 冻结格式）
        let aUUID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let bUUID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let cUUID = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        let displayA36 = Displays.Info(id: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), uuid: aUUID)
        let displayB36 = Displays.Info(id: 2, bounds: CGRect(x: 2000, y: 0, width: 1000, height: 1000), uuid: bUUID)
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report(ok: 1, skip: 2, fail: 0))
        let store = try makeStore(topologies: [[aUUID, bUUID, cUUID]])
        let box = DisplayBox([displayA36, displayB36])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: nil,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil, onNotice: { _ in })

        let notice = chain.restoreNow()

        XCTAssertEqual(restorer.snapshots.first.map { $0.topology.map(\.uuid).sorted() },
                       [aUUID, bUUID, cUUID].sorted(), "选超集快照 best-effort 单屏恢复")
        XCTAssertEqual(notice?.title, "恢复完成")
        XCTAssertEqual(spy.all.filter { $0.contains("step=topology-match") }.first?.contains("result=best-effort"),
                       true, "非精确匹配在日志标注 best-effort")
    }

    func testTopologyKeyRoundTripParsesFixedWidthUUIDSegments() throws {
        // 拓扑键反拆：36 字符段 + "-" 连接（SnapshotStore 冻结格式）无歧义还原 UUID 集合
        let aUUID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let bUUID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let key = SnapshotStore.topologyKey(forDisplayUUIDs: [aUUID, bUUID])
        XCTAssertEqual(TriggerChain.uuids(inTopologyKey: key)?.sorted(), [aUUID, bUUID])
        XCTAssertNil(TriggerChain.uuids(inTopologyKey: "short-fake-key"), "非冻结格式拒拆")
    }

    // MARK: - 周期 6：稳定判据中的新事件（插拔二段事件）不中断链；恢复中事件忽略

    func testEventDuringStabilizingResumesStabilityAfterDebounce() throws {
        // 插回后 Space 尚在结算时常会再来一次屏幕事件：防抖重置后应回到稳定性采样继续链，
        // 而不是被「集合不变→零动作」误杀（否则二段事件场景自动恢复失效）
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report(ok: 1, skip: 0, fail: 0))
        let spaces = FakeSpaceLists(queue: [["A-uuid#1#0"], ["A-uuid#1#0"]])
        let store = try makeStore(topologies: [["A-uuid", "B-uuid"]])
        let box = DisplayBox([displayA])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: spaces,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil, onNotice: { _ in })

        box.set([displayA, displayB])
        chain.screenParametersChanged()   // 事件 1：插回
        scheduler.step()                  // 防抖 → settle grew → match → space r1 采样
        chain.screenParametersChanged()   // 事件 2（稳定判据进行中，如分辨率重排）：防抖重置
        scheduler.runUntilIdle()

        XCTAssertEqual(restorer.snapshots.count, 1, "二段事件后链继续，仍一次性恢复")
        let steps = triggerSteps(spy.all)
        XCTAssertEqual(steps,
                       ["baseline", "event", "debounce-settle", "topology-match", "space-stable",
                        "event", "debounce-settle", "space-stable", "restore-start", "restore-done", "notify"],
                       "稳定判据中的新事件 → 回到 space-stable 继续（不落零动作分支）")
        let settleResults = spy.all.filter { $0.contains("step=debounce-settle") }
        XCTAssertTrue(settleResults[1].contains("resume=stability"), "第二次 settle 标注回到稳定性采样")
        let stableLines = spy.all.filter { $0.contains("step=space-stable") }
        XCTAssertTrue(stableLines[1].contains("result=stable"))
    }

    func testEventDuringRestoreIsIgnoredAndLogged() throws {
        // 恢复进行中到达的屏幕事件：记 ignored 不打断一次性恢复（spec §6.3 放完即停）
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report(ok: 1, skip: 0, fail: 0))
        let spaces = FakeSpaceLists(queue: [["A-uuid#1#0"], ["A-uuid#1#0"]])
        let store = try makeStore(topologies: [["A-uuid", "B-uuid"]])
        let box = DisplayBox([displayA])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: spaces,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil, onNotice: { _ in })
        restorer.onRestore = { chain.screenParametersChanged() }  // 恢复中同步注入事件

        box.set([displayA, displayB])
        chain.screenParametersChanged()
        scheduler.runUntilIdle()

        XCTAssertEqual(restorer.snapshots.count, 1, "恢复不被打断")
        XCTAssertEqual(triggerSteps(spy.all).filter { $0 == "ignored" }.count, 1, "恢复中事件忽略并落日志")
    }

    func testRestoreNowWithoutMatchingSnapshotReturnsNil() throws {
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report())
        let store = try makeStore(topologies: [])
        let box = DisplayBox([displayA, displayB])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: nil,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil, onNotice: { _ in })

        XCTAssertNil(chain.restoreNow(), "无匹配快照不恢复")
        XCTAssertTrue(restorer.snapshots.isEmpty)
        XCTAssertEqual(spy.all.filter { $0.contains("step=topology-match") }.first?.contains("result=no-snapshot"),
                       true)
    }
}
