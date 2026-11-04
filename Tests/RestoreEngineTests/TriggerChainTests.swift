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
    private var _preserveUndoFlags: [Bool] = []
    /// 每次 restore 的 preserveUndo 实参（余震重放不得覆盖回滚快照）
    var preserveUndoFlags: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return _preserveUndoFlags
    }
    @discardableResult
    func restore(snapshot: Snapshot) throws -> RestoreReport {
        try restore(snapshot: snapshot, preserveUndo: false)
    }
    @discardableResult
    func restore(snapshot: Snapshot, preserveUndo: Bool) throws -> RestoreReport {
        lock.lock(); defer { lock.unlock() }
        _snapshots.append(snapshot)
        _preserveUndoFlags.append(preserveUndo)
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
        .appendingPathComponent("winductor-triggerchain-\(UUID().uuidString)")
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

    func testFastReplugWithinDebounceStillRestores() throws {
        // 实测缺陷（11-03）：拔→插回都落在 1.5s 防抖静默期内，插回事件重置计时，
        // settle 只看到 unchanged → 被误判为「无变化零动作」（A2/A3 分支吞掉真实拔插）。
        // 期望：静默期内见过非基线拓扑 → 按「回到基线」处理，补记 baseline-hold 并完整触发恢复。
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report(ok: 1, skip: 0, fail: 0))
        let spaces = FakeSpaceLists(queue: [["A-uuid#1#0", "B-uuid#1#0"], ["A-uuid#1#0", "B-uuid#1#0"]])
        let store = try makeStore(topologies: [["A-uuid", "B-uuid"]])
        let box = DisplayBox([displayA, displayB])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: spaces,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil, onNotice: { _ in })

        box.set([displayA])            // 拔出
        chain.screenParametersChanged()  // 事件 1（防抖重排，不 settle）
        box.set([displayA, displayB])  // 快速插回
        chain.screenParametersChanged()  // 事件 2（重置计时）
        scheduler.runUntilIdle()       // settle 时已回到基线

        let steps = triggerSteps(spy.all)
        XCTAssertTrue(steps.contains("baseline-hold"), "快速拔插补记 baseline-hold（冻结恢复源）")
        XCTAssertTrue(steps.contains("topology-match"), "不再被零动作分支吞掉")
        XCTAssertTrue(steps.contains("restore-start"), "完整触发恢复")
        XCTAssertEqual(restorer.snapshots.count, 1)
    }

    func testPlugBackToSupersetOfHomeRestores() throws {
        // 实测缺陷（11-03 多段插屏）：基线被中间拓扑降级（home=2 屏），用户插回 3 屏
        // （home ⊂ current）被 guard skip 吞掉且基线同步污染 → 后续事件全部静默。
        // 期望：home 是 current 子集 = 回到基线且超越基线 → 放行，恢复源回退到现存拓扑匹配。
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report(ok: 1, skip: 0, fail: 0))
        let spaces = FakeSpaceLists(queue: [
            ["A-uuid#1#0", "B-uuid#1#0", "C-uuid#1#0"],
            ["A-uuid#1#0", "B-uuid#1#0", "C-uuid#1#0"],
        ])
        let store = try makeStore(topologies: [["A-uuid", "B-uuid"], ["A-uuid", "B-uuid", "C-uuid"]])
        let box = DisplayBox([displayA, displayB])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: spaces,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil, onNotice: { _ in })

        box.set([displayA])               // 拔出（3→1？此处 start 2 屏 → 1 屏）
        chain.screenParametersChanged()
        scheduler.runUntilIdle()          // settle shrank → baseline-hold（home={A,B}）
        box.set([displayA, displayB, displayC])  // 多段插屏完成：3 屏（home 的超集）
        chain.screenParametersChanged()
        scheduler.runUntilIdle()          // settle grew → guard 放行 → match 3 屏快照 → 恢复

        let steps = triggerSteps(spy.all)
        XCTAssertTrue(steps.contains { $0 == "return-home-guard" } || spy.all.contains { $0.contains("superset-of-home") },
                      "guard 放行落日志")
        XCTAssertTrue(steps.contains("topology-match"), "匹配现存 3 屏快照")
        XCTAssertTrue(steps.contains("restore-start"), "完整触发恢复")
        XCTAssertEqual(restorer.snapshots.count, 1)
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
        XCTAssertTrue(triggerResults(spy.all).contains("shrank"))
        XCTAssertTrue(triggerSteps(spy.all).contains("baseline-hold"), "拔出时冻结拔屏前基线")

        box.set([displayA, displayB])  // 插回 = 回到拔屏前拓扑 → 集合变大且精确匹配快照
        chain.screenParametersChanged()
        scheduler.runUntilIdle()
        XCTAssertEqual(restorer.snapshots.count, 1, "回到基线拓扑触发恢复")
        XCTAssertTrue(triggerSteps(spy.all).contains("restore-start"))
    }

    /// 实测缺陷回归：中间态拓扑（拔 2 屏后先插回 1 块）即使精确命中过期快照也不自动恢复；
    /// 回到基线拓扑时恢复源用拔屏前冻结内容（而非被 poller 重写的现势文件）
    func testIntermediateTopologySkipsAutoRestoreAndHomeRestoreUsesHeldContent() throws {
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report(ok: 1, skip: 0, fail: 0))
        let spaces = FakeSpaceLists(queue: [["A-uuid#1#0"], ["A-uuid#1#0"]])
        let store = try makeStore(topologies: [["A-uuid"], ["A-uuid", "B-uuid"]])
        // 预写基线快照（带标记窗口）：拔屏冻结时应读到它
        let homeKey = SnapshotStore.topologyKey(forDisplayUUIDs: ["A-uuid", "B-uuid", "C-uuid"])
        let homeTopology = ["A-uuid", "B-uuid", "C-uuid"].map {
            World.topologyEntry(uuid: $0, name: $0, orientation: 0, x: 0, y: 0, w: 1000, h: 1000)
        }
        let held = Snapshot(capturedAt: Date(timeIntervalSince1970: 1), topology: homeTopology, spaces: [],
                            windows: [SnapshotWindow(bundleID: "held.app", title: "held", siblingIndex: 0,
                                                     displayUUID: "A-uuid", spaceIndex: 1,
                                                     x: 0, y: 0, w: 0.5, h: 0.5, minimized: false)])
        try store.write(held, topologyKey: homeKey)
        let box = DisplayBox([displayA, displayB, displayC])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: spaces,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil, onNotice: { _ in })

        box.set([displayA])            // 拔出两块 → 冻结基线（读到 held.app 内容）
        chain.screenParametersChanged()
        scheduler.runUntilIdle()
        XCTAssertTrue(triggerSteps(spy.all).contains("baseline-hold"))

        // poller 中间态重写：live-{A,B,C} 被换成污染内容
        let polluted = Snapshot(capturedAt: Date(timeIntervalSince1970: 2), topology: homeTopology, spaces: [],
                                windows: [SnapshotWindow(bundleID: "polluter.app", title: "junk", siblingIndex: 0,
                                                         displayUUID: "B-uuid", spaceIndex: 1,
                                                         x: 0, y: 0, w: 0.5, h: 0.5, minimized: false)])
        try store.write(polluted, topologyKey: homeKey)

        box.set([displayA, displayB])  // 中间态：精确命中 {A,B} 过期快照也不许自动恢复
        chain.screenParametersChanged()
        scheduler.runUntilIdle()
        XCTAssertEqual(restorer.snapshots.count, 0, "非基线拓扑的精确匹配不自动恢复")
        XCTAssertTrue(triggerSteps(spy.all).contains("return-home-guard"))

        box.set([displayA, displayB, displayC])  // 回到基线拓扑 → 用冻结内容恢复
        chain.screenParametersChanged()
        scheduler.runUntilIdle()
        XCTAssertEqual(restorer.snapshots.count, 1)
        XCTAssertEqual(restorer.snapshots.first?.windows.first?.bundleID, "held.app",
                       "恢复源是拔屏前冻结内容，而非被 poller 重写的污染文件")
    }

    /// 实测缺陷回归（11-03 03:54 cmux 归位到中屏）：多段拔屏 3→{A,B}→{A} 时第二次 shrank
    /// 把 3 屏冻结点替换成 {A,B}；插回 3 屏走 superset 分支回退现读 live-3，而 poller 在
    /// settle 前已把插屏中间态写进 live-3 → 恢复目标被污染。期望：3 屏冻结点不被降级覆盖。
    func testMultiStageUnplugKeepsOuterHomeSnapshotForReturn() throws {
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report(ok: 1, skip: 0, fail: 0))
        let spaces = FakeSpaceLists(queue: [["A-uuid#1#0"], ["A-uuid#1#0"]])
        let store = try makeStore(topologies: [["A-uuid"], ["A-uuid", "B-uuid"], ["A-uuid", "C-uuid"]])
        let homeKey = SnapshotStore.topologyKey(forDisplayUUIDs: ["A-uuid", "B-uuid", "C-uuid"])
        let homeTopology = ["A-uuid", "B-uuid", "C-uuid"].map {
            World.topologyEntry(uuid: $0, name: $0, orientation: 0, x: 0, y: 0, w: 1000, h: 1000)
        }
        let held = Snapshot(capturedAt: Date(timeIntervalSince1970: 1), topology: homeTopology, spaces: [],
                            windows: [SnapshotWindow(bundleID: "held.app", title: "held", siblingIndex: 0,
                                                     displayUUID: "A-uuid", spaceIndex: 1,
                                                     x: 0, y: 0, w: 0.5, h: 0.5, minimized: false)])
        try store.write(held, topologyKey: homeKey)
        let box = DisplayBox([displayA, displayB, displayC])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: spaces,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil, onNotice: { _ in })

        for stage in [[displayA, displayB], [displayA]] {  // 多段拔屏：先拔 C，再拔 B
            box.set(stage)
            chain.screenParametersChanged()
            scheduler.runUntilIdle()
        }
        // poller 在插回 3 屏后、settle 前把 macOS 中间态写进 live-3
        let polluted = Snapshot(capturedAt: Date(timeIntervalSince1970: 2), topology: homeTopology, spaces: [],
                                windows: [SnapshotWindow(bundleID: "polluter.app", title: "junk", siblingIndex: 0,
                                                         displayUUID: "B-uuid", spaceIndex: 3,
                                                         x: 0, y: 0, w: 0.5, h: 0.5, minimized: false)])
        try store.write(polluted, topologyKey: homeKey)
        for stage in [[displayA, displayC], [displayA, displayB, displayC]] {  // 多段插屏：先 C 后 B
            box.set(stage)
            chain.screenParametersChanged()
            scheduler.runUntilIdle()
        }

        XCTAssertEqual(restorer.snapshots.count, 1, "回到 3 屏触发一次恢复（{A,C} 中间态不触发）")
        XCTAssertEqual(restorer.snapshots.first?.windows.first?.bundleID, "held.app",
                       "恢复源是首段拔屏前的 3 屏冻结内容，而非插屏中间态污染的 live-3")
    }

    /// 实测事故回归（11-03 07:39）：app 在拔屏状态下（重）启动 → 内存冻结点为空；插回时右屏先到
    /// = 中间拓扑 {A,C}，精确命中陈旧 2 屏快照被当成正常拓扑恢复，窗口全乱。期望：启动时按磁盘上
    /// 「当前集合的最大超集拓扑」快照重建冻结点（拔屏后它不可能被写过 = 拔屏前内容）→ 中间拓扑不恢复，
    /// 回到 3 屏用该冻结内容恢复。
    func testLaunchWhileUnpluggedSeedsHomeFromLargestKnownTopology() throws {
        let a = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let b = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let c = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        let dA = Displays.Info(id: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), uuid: a)
        let dB = Displays.Info(id: 2, bounds: CGRect(x: 2000, y: 0, width: 1000, height: 1000), uuid: b)
        let dC = Displays.Info(id: 3, bounds: CGRect(x: 4000, y: 0, width: 1000, height: 1000), uuid: c)
        func snap(_ uuids: [String], _ bundle: String) -> Snapshot {
            Snapshot(capturedAt: Date(timeIntervalSince1970: 1),
                     topology: uuids.map { World.topologyEntry(uuid: $0, name: $0, orientation: 0, x: 0, y: 0, w: 1000, h: 1000) },
                     spaces: [],
                     windows: [SnapshotWindow(bundleID: bundle, title: "t", siblingIndex: 0, displayUUID: a,
                                              spaceIndex: 1, x: 0, y: 0, w: 0.5, h: 0.5, minimized: false)])
        }
        let store = try makeStore(topologies: [])
        try store.write(snap([a, b, c], "home.app"), topologyKey: SnapshotStore.topologyKey(forDisplayUUIDs: [a, b, c]))
        try store.write(snap([a, c], "stale.app"), topologyKey: SnapshotStore.topologyKey(forDisplayUUIDs: [a, c]))
        try store.write(snap([a], "single.app"), topologyKey: SnapshotStore.topologyKey(forDisplayUUIDs: [a]))
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report(ok: 1, skip: 0, fail: 0))
        let spaces = FakeSpaceLists(queue: [["x"], ["x"]])
        let box = DisplayBox([dA])  // 拔屏状态下启动
        let chain = TriggerChain(store: store, restorer: restorer, spaces: spaces,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil, onNotice: { _ in })

        box.set([dA, dC])  // 右屏先到：中间拓扑
        chain.screenParametersChanged()
        scheduler.runUntilIdle()
        XCTAssertEqual(restorer.snapshots.count, 0, "中间拓扑精确命中陈旧快照也不得自动恢复")

        box.set([dA, dB, dC])
        chain.screenParametersChanged()
        scheduler.runUntilIdle()
        XCTAssertEqual(restorer.snapshots.map { $0.windows.first?.bundleID }, ["home.app"],
                       "回到 3 屏：用启动时重建的冻结内容恢复")
    }

    /// 实测事故回归（11-03 07:39）：恢复进行中第二块屏接入，事件记 ignored 后再无人重判拓扑，
    /// 3 屏恢复永不触发且 poller 把乱序布局写进 live-3。期望：恢复结束后重判一次拓扑。
    func testScreenEventDuringRestoreIsReEvaluatedAfterRestore() throws {
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report(ok: 1, skip: 0, fail: 0))
        let spaces = FakeSpaceLists(queue: [["A-uuid#1#0"], ["A-uuid#1#0"], ["A-uuid#1#0"], ["A-uuid#1#0"]])
        let store = try makeStore(topologies: [["A-uuid", "B-uuid"], ["A-uuid", "B-uuid", "C-uuid"]])
        let box = DisplayBox([displayA, displayB])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: spaces,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil, onNotice: { _ in })
        box.set([displayA])
        chain.screenParametersChanged()
        scheduler.runUntilIdle()

        let fired = Unboxed(false)
        restorer.onRestore = { [weak chain] in
            guard !fired.value else { return }
            fired.value = true
            box.set([displayA, displayB, displayC])  // 恢复进行中第三块屏接入
            chain?.screenParametersChanged()
        }
        box.set([displayA, displayB])
        chain.screenParametersChanged()
        scheduler.runUntilIdle()

        XCTAssertEqual(restorer.snapshots.map { $0.topology.count }, [2, 3],
                       "恢复期间的屏幕事件在恢复结束后重判 → 3 屏恢复")
    }

    /// 多段拔屏后回到中间拓扑：该拓扑自己的冻结点仍可用（不因保留外层冻结点而被吞）
    func testMultiStageUnplugReturnToIntermediateUsesItsOwnHeldSnapshot() throws {
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report(ok: 1, skip: 0, fail: 0))
        let spaces = FakeSpaceLists(queue: [["A-uuid#1#0"], ["A-uuid#1#0"]])
        let store = try makeStore(topologies: [["A-uuid"], ["A-uuid", "B-uuid", "C-uuid"]])
        let midKey = SnapshotStore.topologyKey(forDisplayUUIDs: ["A-uuid", "B-uuid"])
        let midTopology = ["A-uuid", "B-uuid"].map {
            World.topologyEntry(uuid: $0, name: $0, orientation: 0, x: 0, y: 0, w: 1000, h: 1000)
        }
        let box = DisplayBox([displayA, displayB, displayC])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: spaces,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil, onNotice: { _ in })

        box.set([displayA, displayB])  // 3→2：用户在 2 屏上工作，live-{A,B} 落下 2 屏布局
        chain.screenParametersChanged()
        scheduler.runUntilIdle()
        let midHeld = Snapshot(capturedAt: Date(timeIntervalSince1970: 1), topology: midTopology, spaces: [],
                               windows: [SnapshotWindow(bundleID: "mid.app", title: "mid", siblingIndex: 0,
                                                        displayUUID: "B-uuid", spaceIndex: 1,
                                                        x: 0, y: 0, w: 0.5, h: 0.5, minimized: false)])
        try store.write(midHeld, topologyKey: midKey)
        box.set([displayA])            // 2→1：冻结 {A,B}，且不丢 3 屏冻结点
        chain.screenParametersChanged()
        scheduler.runUntilIdle()
        box.set([displayA, displayB])  // 1→2：回到 {A,B} = 其冻结点的拓扑 → 恢复
        chain.screenParametersChanged()
        scheduler.runUntilIdle()

        XCTAssertEqual(restorer.snapshots.count, 1)
        XCTAssertEqual(restorer.snapshots.first?.windows.first?.bundleID, "mid.app")
    }

    /// 结构门槛：持有基线时，Space 结构与基线不一致期间不得 stable；一致后两轮才开火
    func testHeldBaselineStructureGatesStability() throws {
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report(ok: 1, skip: 0, fail: 0))
        // 队列：前两轮结构与基线不符（churn），后两轮一致
        let spaces = FakeSpaceLists(queue: [["B-uuid#1#0"], ["B-uuid#1#0"],
                                            ["A-uuid#1#0"], ["A-uuid#1#0"]])
        var snapshot = makeSnapshot(topology: ["A-uuid", "B-uuid"])
        snapshot.spaces = [SnapshotSpace(displayUUID: "A-uuid", index: 1, kind: .user, fullscreenAppBundleID: nil)]
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("winductor-triggerchain-\(UUID().uuidString)")
        let store = SnapshotStore(directory: dir)
        try store.write(snapshot, topologyKey: SnapshotStore.topologyKey(forDisplayUUIDs: ["A-uuid", "B-uuid"]))
        let box = DisplayBox([displayA])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: spaces,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil, onNotice: { _ in })

        box.set([displayA, displayB])  // 纯插回（无拔出）：基线快照带 Space 结构 → 门槛生效
        chain.screenParametersChanged()
        scheduler.runUntilIdle()

        XCTAssertEqual(restorer.snapshots.count, 1, "结构一致后两轮 stable 恢复")
        XCTAssertTrue(triggerResults(spy.all).contains("structure-changed"), "结构不符期间不得 stable")
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

        box.set([displayA, displayB])  // 同集合再来事件（睡眠唤醒等价形态；余震窗外——窗内重放见 TriggerChainAftershockTests）
        clock.set(clock.current.addingTimeInterval(TriggerChainConstants.aftershockWindow + 1))
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

    // MARK: 异步手动入口（菜单路径不阻塞调用线程；管线经注入执行器离开主线程）

    /// restoreNowAsync：选择在调用线程、管线经注入执行器执行、完成通知照常投递（与同步形态同一管线）
    func testRestoreNowAsyncRunsPipelineViaEnqueueAndDelivers() throws {
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report(ok: 2, skip: 0, fail: 0))
        let notices = NoticeRecorder()
        let store = try makeStore(topologies: [["A-uuid", "B-uuid"]])
        let box = DisplayBox([displayA, displayB])
        let enqueuedFlag = EnqueueFlagBox()
        let chain = TriggerChain(store: store, restorer: restorer, spaces: nil,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil,
                                 restoreEnqueue: { work in enqueuedFlag.used = true; work() },
                                 onNotice: { notices.append($0) })

        chain.restoreNowAsync()

        XCTAssertEqual(restorer.snapshots.count, 1, "管线经注入执行器执行一次")
        XCTAssertEqual(enqueuedFlag.used, true)
        XCTAssertEqual(notices.items.first?.trigger, .manual, "完成通知与同步形态同结构同投递")
        let steps = triggerSteps(spy.all)
        XCTAssertTrue(steps.contains("restore-start"))
        XCTAssertFalse(steps.contains("event"), "手动入口不经屏幕事件/方向判定")
    }

    /// 重入忙守卫：恢复进行中再入异步入口 → ignored 落日志、不二次恢复
    func testRestoreNowAsyncReentrantWhileRestoringIsIgnored() throws {
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report(ok: 1, skip: 0, fail: 0))
        let store = try makeStore(topologies: [["A-uuid", "B-uuid"]])
        let box = DisplayBox([displayA, displayB])
        let chainBox = ChainBox()
        let chain = TriggerChain(store: store, restorer: restorer, spaces: nil,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: spy, degradeCollector: nil,
                                 restoreEnqueue: { work in work() },
                                 onNotice: { _ in })
        chainBox.chain = chain
        restorer.onRestore = { chainBox.chain?.restoreNowAsync() }  // 引擎执行中重入（真忙态）

        chain.restoreNowAsync()

        XCTAssertEqual(restorer.snapshots.count, 1, "忙态重入不二次恢复")
        XCTAssertEqual(triggerSteps(spy.all).filter { $0 == "ignored" }.count, 1,
                       "重入命中 restore-in-progress 守卫并落日志")
    }
}

/// 执行器使用标记（测试断言辅助）
final class EnqueueFlagBox: @unchecked Sendable {
    var used = false
}

/// 链引用盒（重入测试用：初始化后回填）
final class ChainBox: @unchecked Sendable {
    weak var chain: TriggerChain?
}

private final class Unboxed<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

// MARK: - 余震重放（恢复提速后的正确性补丁）

/// 实测缺陷（11-03 08:42/08:43）：插回第三屏后 macOS 还会再发一次屏幕事件（2–6s 后，集合不变）并重排窗口。
/// 提速前恢复本身要 5–13s，L1 天然落在这次余震之后；提速后恢复 0.2s 就结束，L1 被余震覆盖，
/// poller 再把被覆盖的几何写进 live 快照成为下次恢复基线（herdr 左缘贴边、WeCom x=0）。
/// 期望：自动恢复结束后的余震窗内，集合不变的 settle 用同一冻结快照重放恢复（不重写回滚快照、不重复通知）。
final class TriggerChainAftershockTests: XCTestCase {
    private struct Rig {
        let clock: FakeTriggerClock
        let scheduler: FakeTriggerScheduler
        let spy: LogSpy
        let restorer: FakeSnapshotRestorer
        let notices: NoticeRecorder
        let box: DisplayBox
        let chain: TriggerChain
    }

    private func makeRig() throws -> Rig {
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let spy = LogSpy()
        let restorer = FakeSnapshotRestorer(report: report(ok: 1, skip: 0, fail: 0))
        let spaces = FakeSpaceLists(queue: Array(repeating: ["B-uuid#1#0"], count: 32))
        let notices = NoticeRecorder()
        let store = try makeStore(topologies: [["A-uuid", "B-uuid"]])
        let box = DisplayBox([displayA])
        let chain = TriggerChain(
            store: store, restorer: restorer, spaces: spaces,
            displaysProvider: { box.displays },
            clock: clock, scheduler: scheduler, log: spy, degradeCollector: nil,
            onNotice: { notices.append($0) })
        box.set([displayA, displayB])  // 插回 B → 首轮自动恢复
        chain.screenParametersChanged()
        scheduler.runUntilIdle()
        return Rig(clock: clock, scheduler: scheduler, spy: spy, restorer: restorer,
                   notices: notices, box: box, chain: chain)
    }

    private func lateEvent(_ rig: Rig, after seconds: TimeInterval) {
        rig.clock.set(rig.clock.current.addingTimeInterval(seconds))
        rig.chain.screenParametersChanged()
        rig.scheduler.runUntilIdle()
    }

    func testAftershockWithinWindowReappliesSameSnapshotPreservingUndoWithoutSecondNotice() throws {
        let rig = try makeRig()
        XCTAssertEqual(rig.restorer.snapshots.count, 1)

        lateEvent(rig, after: 2)  // 恢复结束 2s 后余震（集合不变）

        XCTAssertEqual(rig.restorer.snapshots.count, 2, "余震后重放一次")
        XCTAssertEqual(rig.restorer.snapshots.last?.topology.map(\.uuid).sorted(), ["A-uuid", "B-uuid"])
        XCTAssertEqual(rig.restorer.preserveUndoFlags, [false, true], "重放不得覆盖首轮的回滚快照")
        XCTAssertEqual(rig.notices.items.count, 1, "重放不重复弹完成通知")
        XCTAssertTrue(triggerSteps(rig.spy.all).contains("aftershock-reapply"))
        XCTAssertEqual(rig.scheduler.pendingCount, 0)
    }

    func testEventAfterWindowIsZeroAction() throws {
        let rig = try makeRig()
        lateEvent(rig, after: TriggerChainConstants.aftershockWindow + 5)
        XCTAssertEqual(rig.restorer.snapshots.count, 1, "余震窗外的集合不变事件仍是零动作（A2/A3）")
    }

    func testReapplyIsCappedPerRestore() throws {
        let rig = try makeRig()
        for _ in 0..<4 { lateEvent(rig, after: 1) }
        XCTAssertEqual(rig.restorer.snapshots.count, 1 + TriggerChainConstants.aftershockMaxReapplies,
                       "重放有上限，不构成循环")
    }

    /// 提速（11-03 09:28 实测余震 → 重放纠正 2.7s = 防抖 1.5s + 稳定两轮 0.5s + 恢复）：
    /// 余震重放走短防抖，且 Space/显示器签名与上次开火时一致即开火（不再等第二轮采样）
    func testAftershockReapplyFiresAfterShortDebounceWhenSignatureMatchesLastFire() throws {
        let rig = try makeRig()
        let before = rig.spy.all.count

        lateEvent(rig, after: 2)

        let lines = Array(rig.spy.all.dropFirst(before))
        let steps = triggerSteps(lines)
        let stamps = triggerTimestamps(lines)
        XCTAssertEqual(steps, ["event", "debounce-settle", "aftershock-reapply", "space-stable",
                               "restore-start", "restore-done"])
        let start = try XCTUnwrap(steps.firstIndex(of: "restore-start"))
        XCTAssertEqual(stamps[start].timeIntervalSince(stamps[0]),
                       TriggerChainConstants.aftershockDebounceQuietPeriod, accuracy: 0.001,
                       "余震事件 → 重放开工 = 短防抖，无额外采样轮")
        XCTAssertEqual(rig.restorer.snapshots.count, 2)
    }

    /// 余震改了显示器排列（集合不变、bounds 变）：签名与上次开火不一致 → 退回连续两轮判据
    func testAftershockWithChangedDisplayGeometryFallsBackToTwoRoundStability() throws {
        let rig = try makeRig()
        let before = rig.spy.all.count
        let movedB = Displays.Info(id: 2, bounds: CGRect(x: 1000, y: 0, width: 1000, height: 1000), uuid: "B-uuid")
        rig.box.set([displayA, movedB])

        lateEvent(rig, after: 2)

        let lines = Array(rig.spy.all.dropFirst(before))
        let steps = triggerSteps(lines)
        let stamps = triggerTimestamps(lines)
        XCTAssertEqual(triggerResults(lines.filter { $0.contains("step=space-stable") }), ["changed", "stable"])
        let start = try XCTUnwrap(steps.firstIndex(of: "restore-start"))
        XCTAssertEqual(stamps[start].timeIntervalSince(stamps[0]),
                       TriggerChainConstants.aftershockDebounceQuietPeriod + TriggerChainConstants.spaceStableInterval,
                       accuracy: 0.001)
        XCTAssertEqual(rig.restorer.snapshots.count, 2)
    }

    /// 短防抖只给余震：恢复后窗内拔屏（集合变化）仍走 1.5s 防抖
    func testNonAftershockEventInWindowKeepsNormalDebounce() throws {
        let rig = try makeRig()
        let before = rig.spy.all.count
        rig.box.set([displayA])

        lateEvent(rig, after: 1)

        let lines = Array(rig.spy.all.dropFirst(before))
        let stamps = triggerTimestamps(lines)
        XCTAssertEqual(Array(triggerSteps(lines).prefix(2)), ["event", "debounce-settle"])
        XCTAssertEqual(stamps[1].timeIntervalSince(stamps[0]), TriggerChainConstants.debounceQuietPeriod,
                       accuracy: 0.001)
    }

    /// 余震预判落空（审查 #2）：事件到达时屏幕源尚未反映新集合 → 预判为余震走短防抖；
    /// settle 时集合已变 → 补足普通防抖再判定（普通插拔时序不受短防抖影响）
    func testMissedAftershockPredictionExtendsToNormalDebounce() throws {
        let rig = try makeRig()
        let before = rig.spy.all.count
        rig.clock.set(rig.clock.current.addingTimeInterval(1))
        rig.chain.screenParametersChanged()   // 屏幕源仍是 {A,B}：预判余震
        rig.box.set([displayA])                // 防抖期内才反映拔屏
        rig.scheduler.runUntilIdle()

        let lines = Array(rig.spy.all.dropFirst(before))
        let steps = triggerSteps(lines)
        let stamps = triggerTimestamps(lines)
        XCTAssertEqual(Array(steps.prefix(3)), ["event", "debounce-extend", "debounce-settle"])
        XCTAssertEqual(stamps[2].timeIntervalSince(stamps[0]), TriggerChainConstants.debounceQuietPeriod,
                       accuracy: 0.001)
        XCTAssertTrue(lines[2].contains("result=shrank"))
    }

    func testShrinkClearsAftershockState() throws {
        let rig = try makeRig()
        rig.box.set([displayA])          // 恢复后立刻拔屏
        lateEvent(rig, after: 1)
        rig.box.set([displayA])
        lateEvent(rig, after: 1)         // 集合不变事件（{A}）：不得重放 {A,B} 快照
        XCTAssertEqual(rig.restorer.snapshots.count, 1)
    }
}

// MARK: - 冻结点取自事件串起点（防拔屏中途写盘污染）

/// 实测缺陷（11-03 09:08）：拔屏首个事件后 2.2s，在途写盘把拔屏中途态落进 live-<拔屏前拓扑>，
/// settle(shrank) 时现读冻结 → 冻结了垃圾。期望：冻结内容取自本串事件首个到达时的 live 快照。
final class TriggerChainBurstBaselineTests: XCTestCase {
    func testShrinkFreezesLiveSnapshotAsOfFirstEventNotAtSettle() throws {
        let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
        let scheduler = FakeTriggerScheduler(clock: clock)
        let restorer = FakeSnapshotRestorer(report: report(ok: 1, skip: 0, fail: 0))
        let spaces = FakeSpaceLists(queue: Array(repeating: ["A-uuid#1#0", "B-uuid#1#0"], count: 8))
        let store = try makeStore(topologies: [["A-uuid", "B-uuid"]])
        let key = SnapshotStore.topologyKey(forDisplayUUIDs: ["A-uuid", "B-uuid"])
        let good = try XCTUnwrap(store.loadLive(topologyKey: key))
        let box = DisplayBox([displayA, displayB])
        let chain = TriggerChain(store: store, restorer: restorer, spaces: spaces,
                                 displaysProvider: { box.displays }, clock: clock, scheduler: scheduler,
                                 log: LogSpy(), degradeCollector: nil, onNotice: { _ in })

        box.set([displayA])                // 拔出 B：事件串首个事件
        chain.screenParametersChanged()
        // 防抖期内在途写盘把拔屏中途态落进 live-{A,B}（同拓扑键、内容是垃圾）
        var polluted = makeSnapshot(topology: ["A-uuid", "B-uuid"])
        polluted = Snapshot(capturedAt: Date(timeIntervalSince1970: 42), topology: polluted.topology,
                            spaces: polluted.spaces, windows: polluted.windows)
        try store.write(polluted, topologyKey: key)
        scheduler.runUntilIdle()           // settle: shrank → 冻结

        box.set([displayA, displayB])      // 插回
        chain.screenParametersChanged()
        scheduler.runUntilIdle()

        XCTAssertEqual(restorer.snapshots.count, 1)
        XCTAssertEqual(restorer.snapshots.first?.capturedAt, good.capturedAt,
                       "恢复源应是首个事件时的 live 快照，而非防抖期内被污染的版本")
    }
}
