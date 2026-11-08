@testable import Core
@testable import RestoreEngine  // @testable：测试需构造 RestoreReport（memberwise init 为 internal）
import CoreGraphics
import Foundation
import SnapshotEngine
import XCTest

// TriggerChainTests — 触发链按预设判定（display-presets spec §5.1，票 04；fake 注入单测）。
// 断言口径：[trigger] 结构化日志的 step 序列 + at= 时间戳链、恢复器收到的快照、onOutcome 收到的判定结果、
// PresetStore 公开读接口（最近恢复记录）。拓扑经注入的 ObservedTopology 源驱动，预设存于临时目录的真实 PresetStore。

// MARK: - fake 注入桩

/// 虚拟时钟：测试手动推进，触发链日志的 at= 时间戳可精确断言
final class FakeTriggerClock: TriggerClockProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(start: Date) { _now = start }
    var current: Date {
        get { lock.lock(); defer { lock.unlock() }; return _now }
        set { lock.lock(); _now = newValue; lock.unlock() }
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
    private var last: [String]?
    init(queue: [[String]?]) { self.queue = queue }
    func spaceList() -> [String]? {
        lock.lock(); defer { lock.unlock() }
        guard !queue.isEmpty else { return last }
        last = queue.removeFirst()
        return last
    }
}

/// 恢复器 fake：记录 restore 调用，可注入返回报告、抛错与副作用；取消令牌原样暴露给测试
final class FakeSnapshotRestorer: SnapshotRestoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshots: [Snapshot] = []
    private var _preserveUndoFlags: [Bool] = []
    var report: RestoreReport
    var error: Error?
    /// restore 执行中的副作用（参数 = 本轮取消令牌；模拟恢复中拓扑变化 / 降级日志）
    var onRestore: ((RestoreCancellation?) -> Void)?
    init(report: RestoreReport) { self.report = report }
    var snapshots: [Snapshot] { lock.lock(); defer { lock.unlock() }; return _snapshots }
    var preserveUndoFlags: [Bool] { lock.lock(); defer { lock.unlock() }; return _preserveUndoFlags }

    func restore(snapshot: Snapshot) throws -> RestoreReport {
        try restore(snapshot: snapshot, preserveUndo: false, cancellation: nil)
    }
    func restore(snapshot: Snapshot, preserveUndo: Bool, cancellation: RestoreCancellation?) throws -> RestoreReport {
        lock.lock()
        _snapshots.append(snapshot)
        _preserveUndoFlags.append(preserveUndo)
        let hook = onRestore
        lock.unlock()
        hook?(cancellation)
        if let error { throw error }
        var result = report
        // 真实引擎口径：令牌已取消 → 报告 cancelled
        if cancellation?.isCancelled == true { result.cancelled = true }
        return result
    }
}

/// 收集器（通知 / 判定结果）
final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [T] = []
    var items: [T] { lock.lock(); defer { lock.unlock() }; return _items }
    func append(_ item: T) { lock.lock(); _items.append(item); lock.unlock() }
}

/// 拓扑源 fake：测试中改屏幕组合模拟拔插 / 改排列 / 镜像
final class TopologyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _screens: [TopologyScreen]
    init(_ screens: [TopologyScreen]) { _screens = screens }
    var observed: ObservedTopology {
        lock.lock(); defer { lock.unlock() }
        return ObservedTopology(screens: _screens)
    }
    func set(_ screens: [TopologyScreen]) { lock.lock(); _screens = screens; lock.unlock() }
}

/// 可变布尔盒（就绪门注入）
final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    init(_ value: Bool) { _value = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

// MARK: - 场景构造

/// 屏 A 在左、B 在 A 右侧贴合、C 在 B 右侧贴合（邻接排列 = 拓扑身份）
private func screen(_ uuid: String, x: CGFloat, width: CGFloat = 1000, pixelWidth: Int = 2000,
                    rotation: Int = 0, mirrored: Bool = false) -> TopologyScreen {
    TopologyScreen(uuid: uuid, name: uuid, frame: CGRect(x: x, y: 0, width: width, height: 1000),
                   pixelWidth: pixelWidth, pixelHeight: 2000, rotation: rotation, isMirrored: mirrored)
}
private let screenA = screen("A-uuid", x: 0)
private let screenB = screen("B-uuid", x: 1000)
private let screenC = screen("C-uuid", x: 2000)

private func makeSnapshot(_ tag: String, topology uuids: [String]) -> Snapshot {
    Snapshot(
        capturedAt: Date(timeIntervalSince1970: 0),
        topology: uuids.map { World.topologyEntry(uuid: $0, name: $0, orientation: 0, x: 0, y: 0, w: 1000, h: 1000) },
        spaces: [],
        windows: [SnapshotWindow(bundleID: tag, title: tag, siblingIndex: 0, displayUUID: uuids[0],
                                 spaceIndex: 1, x: 0, y: 0, w: 0.5, h: 0.5, minimized: false)])
}

private func report(ok: Int = 0, skip: Int = 0, fail: Int = 0) -> RestoreReport {
    RestoreReport(okCount: ok, skipCount: skip, failCount: fail,
                  matchedCount: ok, untouchedLiveCount: 0, undoSnapshotURL: nil)
}

/// [trigger] 行的 step= 记号序列
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

/// [trigger] 行的 at= 时间戳序列
private func triggerTimestamps(_ lines: [String]) -> [Date] {
    lines.filter { $0.contains("[trigger]") }.compactMap { line in
        line.split(separator: " ").first(where: { $0.hasPrefix("at=") })
            .flatMap { chainTimestampFormatter.date(from: String($0.dropFirst(3))) }
    }
}

/// 测试台：真实 PresetStore（临时目录）+ 全 fake 接缝；链在 init 时以 start 拓扑为基线
private final class Rig {
    let clock = FakeTriggerClock(start: Date(timeIntervalSince1970: 1_000_000))
    let scheduler: FakeTriggerScheduler
    let spy = LogSpy()
    let restorer = FakeSnapshotRestorer(report: report(ok: 2, skip: 1, fail: 0))
    let notices = Recorder<RestoreNotice>()
    let outcomes = Recorder<TriggerOutcome>()
    let topology: TopologyBox
    let ready = FlagBox(true)
    let store: PresetStore
    var spaces: FakeSpaceLists
    private(set) var chain: TriggerChain!

    init(start: [TopologyScreen], dir: URL, spaces: FakeSpaceLists = FakeSpaceLists(queue: [["s"]])) {
        scheduler = FakeTriggerScheduler(clock: clock)
        topology = TopologyBox(start)
        store = PresetStore(directory: dir)
        self.spaces = spaces
    }

    /// 建链（预设写好之后调；init 读基线拓扑）
    @discardableResult
    func makeChain(restoreEnqueue: ((@escaping @Sendable () -> Void) -> Void)? = nil) -> TriggerChain {
        let topology = self.topology, ready = self.ready, notices = self.notices, outcomes = self.outcomes
        chain = TriggerChain(
            presets: store, restorer: restorer, spaces: spaces,
            topologyProvider: { topology.observed },
            readiness: { ready.value },
            clock: clock, scheduler: scheduler, log: spy, degradeCollector: nil,
            restoreEnqueue: restoreEnqueue ?? { $0() },
            onNotice: { notices.append($0) },
            onOutcome: { outcomes.append($0) })
        return chain
    }

    /// 在给定屏幕组合下存一个预设（auto: nil = 沿用存储默认规则）
    @discardableResult
    func addPreset(_ name: String, on screens: [TopologyScreen], auto: Bool? = nil) throws -> Preset {
        let observed = ObservedTopology(screens: screens)
        let preset = try store.addPreset(name: name, snapshot: makeSnapshot(name, topology: screens.map(\.uuid)),
                                         topology: observed)
        if let auto { try store.setAuto(auto, presetID: preset.id, topologyKey: observed.identity.key) }
        return preset
    }

    /// 改屏幕组合并发一次屏幕参数事件，跑完调度
    func change(to screens: [TopologyScreen]) {
        topology.set(screens)
        chain.screenParametersChanged()
        scheduler.runUntilIdle()
    }

    func key(_ screens: [TopologyScreen]) -> String { ObservedTopology(screens: screens).identity.key }
}

// MARK: - 判定表（spec §5.1 四行）

final class TriggerChainTests: XCTestCase {
    private func rig(start: [TopologyScreen], spaces: FakeSpaceLists = FakeSpaceLists(queue: [["s"]])) throws -> Rig {
        Rig(start: start, dir: try makeTempDir(), spaces: spaces)
    }

    /// 有自动预设：拓扑变化 → 防抖 1.5s → Space 稳定 500ms×2 → 直接恢复该预设 → 记录最近恢复 → 自动恢复告知
    func testAutoPresetRestoresDirectlyWithProvableTimestampChain() throws {
        let rig = try rig(start: [screenA])
        let preset = try rig.addPreset("工作", on: [screenA, screenB])  // 首个预设默认自动
        rig.makeChain()

        rig.change(to: [screenA, screenB])

        XCTAssertEqual(rig.restorer.snapshots.map { $0.windows.first?.bundleID }, ["工作"], "恢复的是该拓扑的自动预设")
        XCTAssertEqual(rig.restorer.preserveUndoFlags, [false])
        let steps = triggerSteps(rig.spy.all)
        XCTAssertEqual(steps, ["baseline", "event", "debounce-settle", "space-stable", "space-stable",
                               "topology-match", "restore-start", "restore-done", "outcome"])
        let stamps = triggerTimestamps(rig.spy.all)
        XCTAssertEqual(stamps.count, steps.count)
        XCTAssertEqual(stamps[2].timeIntervalSince(stamps[1]), 1.5, accuracy: 0.001, "防抖静默期 1.5s")
        XCTAssertEqual(stamps[4].timeIntervalSince(stamps[3]), 0.5, accuracy: 0.001, "Space 稳定轮间隔 500ms")
        XCTAssertEqual(rig.store.topology(key: rig.key([screenA, screenB]))?.lastRestoredPresetID, preset.id,
                       "恢复成功后记录最近恢复预设")
        XCTAssertEqual(rig.outcomes.items, [.autoRestored(AutoRestoredOutcome(
            topologyKey: rig.key([screenA, screenB]), presetID: preset.id, presetName: "工作",
            notice: RestoreCompletionNotice(trigger: .auto, okCount: 2, skipCount: 1, failCount: 0,
                                            degradedLayerNames: [], failureDetail: nil),
            hasOtherPresets: false))])
        XCTAssertTrue(rig.notices.items.isEmpty, "自动恢复不走系统通知接缝（告知归 onOutcome，票 05）")
        XCTAssertEqual(rig.scheduler.pendingCount, 0)
    }

    /// 有预设但无自动：不恢复，请求恢复提示（载荷 = 该拓扑与预设列表）
    func testPresetsWithoutAutoRequestPrompt() throws {
        let rig = try rig(start: [screenA])
        let first = try rig.addPreset("工作", on: [screenA, screenB], auto: false)
        try rig.addPreset("演示", on: [screenA, screenB])
        rig.makeChain()

        rig.change(to: [screenA, screenB])

        XCTAssertTrue(rig.restorer.snapshots.isEmpty, "无自动预设不恢复")
        let topology = try XCTUnwrap(rig.store.topology(key: rig.key([screenA, screenB])))
        XCTAssertEqual(rig.outcomes.items, [.promptNeeded(topology)])
        XCTAssertEqual(topology.presets.map(\.id).first, first.id)
        XCTAssertEqual(triggerResults(rig.spy.all).suffix(2), ["prompt", "prompt"], "topology-match=prompt → outcome=prompt")
    }

    /// 拓扑无预设：零动作，并要求收起恢复提示
    func testNoPresetIsZeroActionAndDismissesPrompt() throws {
        let rig = try rig(start: [screenA])
        try rig.addPreset("单屏", on: [screenA])  // 其他拓扑的预设不算
        rig.makeChain()

        rig.change(to: [screenA, screenB])

        XCTAssertTrue(rig.restorer.snapshots.isEmpty)
        XCTAssertEqual(rig.outcomes.items, [.dismissPrompt])
        XCTAssertEqual(triggerSteps(rig.spy.all).filter { $0 == "restore-start" }.count, 0)
        XCTAssertTrue(rig.spy.all.contains { $0.contains("step=topology-match") && $0.contains("result=no-preset") })
    }

    /// 镜像中：即使有自动预设也零动作（不恢复、不弹提示）
    func testMirroredTopologyIsZeroAction() throws {
        let rig = try rig(start: [screenA])
        let mirroredB = screen("B-uuid", x: 1000, mirrored: true)
        // 镜像下禁止保存：预设存在非镜像同身份拓扑下（键相同）
        try rig.addPreset("工作", on: [screenA, screenB])
        rig.makeChain()

        rig.change(to: [screenA, mirroredB])

        XCTAssertTrue(rig.restorer.snapshots.isEmpty, "镜像中不自动恢复")
        XCTAssertEqual(rig.outcomes.items, [.dismissPrompt], "镜像中不弹提示（开着的提示收起）")
        XCTAssertTrue(rig.spy.all.contains { $0.contains("result=mirrored") })
    }

    /// 未就绪（授权未齐）：即使有自动预设也零动作
    func testNotReadyIsZeroAction() throws {
        let rig = try rig(start: [screenA])
        try rig.addPreset("工作", on: [screenA, screenB])
        rig.ready.value = false
        rig.makeChain()

        rig.change(to: [screenA, screenB])

        XCTAssertTrue(rig.restorer.snapshots.isEmpty)
        XCTAssertEqual(rig.outcomes.items, [.dismissPrompt])
        XCTAssertTrue(rig.spy.all.contains { $0.contains("result=not-ready") })
    }

    /// 不再区分集合变大/变小：拔到单屏且单屏有自动预设 → 恢复
    func testUnplugToSingleScreenWithAutoPresetRestores() throws {
        let rig = try rig(start: [screenA, screenB, screenC])
        try rig.addPreset("三屏", on: [screenA, screenB, screenC])
        let single = try rig.addPreset("笔记本", on: [screenA])
        rig.makeChain()

        rig.change(to: [screenA])

        XCTAssertEqual(rig.restorer.snapshots.map { $0.windows.first?.bundleID }, ["笔记本"])
        XCTAssertEqual(rig.store.topology(key: rig.key([screenA]))?.lastRestoredPresetID, single.id)
    }

    /// 排列变化（右屏拖到左边）= 另一拓扑 → 判定
    func testRearrangementIsATopologyChange() throws {
        let rig = try rig(start: [screenA, screenB])
        let bLeft = screen("B-uuid", x: -1000)
        try rig.addPreset("右侧", on: [screenA, screenB])
        try rig.addPreset("左侧", on: [screenA, bLeft])
        rig.makeChain()

        rig.change(to: [screenA, bLeft])

        XCTAssertEqual(rig.restorer.snapshots.map { $0.windows.first?.bundleID }, ["左侧"])
    }

    // MARK: - 拓扑未变的事件零动作；启动不判定

    /// 睡眠唤醒 / 锁屏解锁（屏幕组合不变）与分辨率调整（分辨率不参与身份）→ 零动作
    func testWakeLockAndResolutionChangeAreZeroAction() throws {
        let rig = try rig(start: [screenA, screenB])
        try rig.addPreset("工作", on: [screenA, screenB])
        rig.makeChain()

        rig.change(to: [screenA, screenB])                                    // 睡眠唤醒 / 锁屏解锁
        rig.change(to: [screen("A-uuid", x: 0, pixelWidth: 3840), screenB])   // 分辨率 4K ↔ 1440p

        XCTAssertTrue(rig.restorer.snapshots.isEmpty, "拓扑未变不恢复")
        XCTAssertTrue(rig.outcomes.items.isEmpty, "拓扑未变不弹提示也不收起")
        XCTAssertEqual(triggerSteps(rig.spy.all),
                       ["baseline", "event", "debounce-settle", "event", "debounce-settle"],
                       "链止于 debounce-settle")
        XCTAssertEqual(triggerResults(rig.spy.all), ["unchanged", "unchanged"])
        XCTAssertEqual(rig.scheduler.pendingCount, 0)
    }

    /// 应用启动时不判定：建链时拓扑有自动预设也不恢复、不弹提示
    func testLaunchDoesNotJudge() throws {
        let rig = try rig(start: [screenA, screenB])
        try rig.addPreset("工作", on: [screenA, screenB])

        rig.makeChain()

        XCTAssertTrue(rig.restorer.snapshots.isEmpty)
        XCTAssertTrue(rig.outcomes.items.isEmpty)
        XCTAssertEqual(rig.scheduler.pendingCount, 0, "建链不排任何判定")
        XCTAssertEqual(triggerSteps(rig.spy.all), ["baseline"])
    }

    /// 快速拔→插回都落在防抖静默期内：settle 时已回到基线，仍按「拓扑变过」判定
    func testFastReplugWithinDebounceIsJudged() throws {
        let rig = try rig(start: [screenA, screenB])
        try rig.addPreset("工作", on: [screenA, screenB])
        rig.makeChain()

        rig.topology.set([screenA])
        rig.chain.screenParametersChanged()
        rig.change(to: [screenA, screenB])

        XCTAssertEqual(rig.restorer.snapshots.count, 1, "不被零动作分支吞掉")
        XCTAssertEqual(triggerResults(rig.spy.all.filter { $0.contains("step=debounce-settle") }), ["changed"])
    }

    // MARK: - 恢复中拓扑变化：中止本轮、记日志、按新拓扑重判

    func testTopologyChangeDuringRestoreCancelsRoundAndRejudges() throws {
        let rig = try rig(start: [screenA])
        let two = try rig.addPreset("双屏", on: [screenA, screenB])
        let three = try rig.addPreset("三屏", on: [screenA, screenB, screenC])
        rig.makeChain()
        let tokens = Recorder<RestoreCancellation?>()
        let fired = FlagBox(false)
        rig.restorer.onRestore = { [rig] token in
            tokens.append(token)
            guard !fired.value else { return }
            fired.value = true
            rig.topology.set([screenA, screenB, screenC])  // 恢复进行中第三块屏接入
            rig.chain.screenParametersChanged()
        }

        rig.change(to: [screenA, screenB])

        XCTAssertEqual(tokens.items.first??.isCancelled, true, "恢复中拓扑变化 → 取消令牌")
        let steps = triggerSteps(rig.spy.all)
        XCTAssertTrue(steps.contains("restore-cancel"), "取消落日志")
        XCTAssertTrue(steps.contains("restore-cancelled"), "本轮中止落日志")
        XCTAssertEqual(rig.restorer.snapshots.map { $0.windows.first?.bundleID }, ["双屏", "三屏"],
                       "按新拓扑重判并恢复其自动预设")
        XCTAssertNil(rig.store.topology(key: rig.key([screenA, screenB]))?.lastRestoredPresetID,
                     "被中止的轮次不记录最近恢复")
        XCTAssertEqual(rig.store.topology(key: rig.key([screenA, screenB, screenC]))?.lastRestoredPresetID, three.id)
        XCTAssertEqual(rig.outcomes.items.compactMap {
            if case .autoRestored(let r) = $0 { return r.presetID } else { return nil }
        }, [three.id], "被中止的轮次不产出告知")
        _ = two
    }

    /// 恢复中来了拓扑不变的事件（如插屏余震提前到达）：不取消，恢复结束后重判
    func testUnchangedTopologyEventDuringRestoreDoesNotCancel() throws {
        let rig = try rig(start: [screenA])
        try rig.addPreset("双屏", on: [screenA, screenB])
        rig.makeChain()
        let tokens = Recorder<RestoreCancellation?>()
        rig.restorer.onRestore = { [rig] token in
            tokens.append(token)
            if tokens.items.count == 1 { rig.chain.screenParametersChanged() }
        }

        rig.change(to: [screenA, screenB])

        XCTAssertEqual(tokens.items.first??.isCancelled, false)
        XCTAssertTrue(triggerSteps(rig.spy.all).contains("ignored"))
        XCTAssertFalse(triggerSteps(rig.spy.all).contains("restore-cancel"))
    }

    // MARK: - Space 稳定判据

    func testSpaceInstabilityRestartsConsecutiveRounds() throws {
        let rig = try rig(start: [screenA], spaces: FakeSpaceLists(queue: [["A#1#0"], ["A#2#0"], ["A#2#0"]]))
        try rig.addPreset("工作", on: [screenA, screenB])
        rig.makeChain()

        rig.change(to: [screenA, screenB])

        XCTAssertEqual(rig.restorer.snapshots.count, 1)
        XCTAssertEqual(triggerResults(rig.spy.all.filter { $0.contains("step=space-stable") }),
                       ["sampled", "changed", "stable"])
    }

    /// 稳定判据进行中来了拓扑不变的新事件：防抖重置后回到采样继续，不落零动作分支
    func testEventDuringStabilizingResumesStability() throws {
        let rig = try rig(start: [screenA])
        try rig.addPreset("工作", on: [screenA, screenB])
        rig.makeChain()

        rig.topology.set([screenA, screenB])
        rig.chain.screenParametersChanged()
        rig.scheduler.step()                 // 防抖 → settle changed → space r1 采样
        rig.chain.screenParametersChanged()  // 二段事件
        rig.scheduler.runUntilIdle()

        XCTAssertEqual(rig.restorer.snapshots.count, 1)
        XCTAssertEqual(triggerSteps(rig.spy.all),
                       ["baseline", "event", "debounce-settle", "space-stable", "event", "debounce-settle",
                        "space-stable", "topology-match", "restore-start", "restore-done", "outcome"])
        XCTAssertTrue(rig.spy.all.filter { $0.contains("step=debounce-settle") }[1].contains("resume=stability"))
    }

    // MARK: - 完成计数、降级附注、失败

    func testAutoRestoreFailureReportsFailureAndDoesNotRecord() throws {
        let rig = try rig(start: [screenA])
        try rig.addPreset("工作", on: [screenA, screenB])
        rig.restorer.error = RestoreEngineError.undoSnapshotWriteFailed("disk-full")
        rig.makeChain()

        rig.change(to: [screenA, screenB])

        guard case .autoRestored(let restored)? = rig.outcomes.items.first else {
            return XCTFail("应产出自动恢复结果（含失败）：\(rig.outcomes.items)")
        }
        XCTAssertEqual(restored.notice.title, "恢复失败")
        XCTAssertEqual(restored.notice.body, "恢复失败：undoSnapshotWriteFailed(\"disk-full\")")
        XCTAssertNil(rig.store.topology(key: rig.key([screenA, screenB]))?.lastRestoredPresetID)
        XCTAssertTrue(triggerSteps(rig.spy.all).contains("restore-failed"))
        XCTAssertEqual(rig.scheduler.pendingCount, 0)
    }

    func testDegradeAnnotationAndOtherPresetsFlag() throws {
        let rig = try rig(start: [screenA])
        try rig.addPreset("工作", on: [screenA, screenB])
        try rig.addPreset("演示", on: [screenA, screenB])
        let collector = DegradeCollectingLog(inner: rig.spy)
        rig.restorer.onRestore = { _ in collector.write("[degrade] layer=L2 reason=probe-miss detail=forced") }
        let topology = rig.topology, outcomes = rig.outcomes
        let chain = TriggerChain(presets: rig.store, restorer: rig.restorer, spaces: rig.spaces,
                                 topologyProvider: { topology.observed }, clock: rig.clock, scheduler: rig.scheduler,
                                 log: collector, degradeCollector: collector, onOutcome: { outcomes.append($0) })

        topology.set([screenA, screenB])
        chain.screenParametersChanged()
        rig.scheduler.runUntilIdle()

        guard case .autoRestored(let restored)? = outcomes.items.first else { return XCTFail("\(outcomes.items)") }
        XCTAssertEqual(restored.notice.degradedLayerNames, ["Space 归属"])
        XCTAssertTrue(restored.hasOtherPresets, "拓扑下还有其他预设 → 告知附「改用其他预设…」")
    }

    // MARK: - 手动恢复（提示「恢复」/ 子菜单；与自动恢复同一管线）

    func testRestorePresetManuallyRecordsAndNotifies() throws {
        let rig = try rig(start: [screenA, screenB])
        try rig.addPreset("工作", on: [screenA, screenB])
        let demo = try rig.addPreset("演示", on: [screenA, screenB])
        rig.makeChain()

        let notice = rig.chain.restorePreset(id: demo.id, topologyKey: rig.key([screenA, screenB]))

        XCTAssertEqual(rig.restorer.snapshots.map { $0.windows.first?.bundleID }, ["演示"])
        XCTAssertEqual(notice?.trigger, .manual)
        XCTAssertEqual(rig.notices.items, [notice].compactMap { $0 }, "手动恢复完成通知经 onNotice")
        XCTAssertEqual(rig.store.topology(key: rig.key([screenA, screenB]))?.lastRestoredPresetID, demo.id)
        XCTAssertFalse(triggerSteps(rig.spy.all).contains("event"), "手动入口不经屏幕事件")
    }

    /// 仅当前拓扑：提示弹出后拓扑已变 → 不恢复
    func testRestorePresetForOtherTopologyIsRejected() throws {
        let rig = try rig(start: [screenA])
        let preset = try rig.addPreset("工作", on: [screenA, screenB])
        rig.makeChain()

        XCTAssertNil(rig.chain.restorePreset(id: preset.id, topologyKey: rig.key([screenA, screenB])))
        XCTAssertTrue(rig.restorer.snapshots.isEmpty)
        XCTAssertTrue(rig.spy.all.contains { $0.contains("result=topology-mismatch") })
    }

    /// 菜单路径（恢复预设子菜单）：选择在调用线程，管线经注入执行器
    func testRestorePresetAsyncRunsViaEnqueue() throws {
        let rig = try rig(start: [screenA, screenB])
        try rig.addPreset("工作", on: [screenA, screenB])
        let demo = try rig.addPreset("演示", on: [screenA, screenB])
        let enqueued = FlagBox(false)
        rig.makeChain(restoreEnqueue: { work in enqueued.value = true; work() })

        rig.chain.restorePresetAsync(id: demo.id, topologyKey: rig.key([screenA, screenB]))

        XCTAssertTrue(enqueued.value)
        XCTAssertEqual(rig.restorer.snapshots.map { $0.windows.first?.bundleID }, ["演示"])
        XCTAssertEqual(rig.store.topology(key: rig.key([screenA, screenB]))?.lastRestoredPresetID, demo.id)
    }

    /// 预设已不存在（菜单打开后在管理窗口删掉）：不恢复
    func testRestoreMissingPresetReturnsNil() throws {
        let rig = try rig(start: [screenA, screenB])
        try rig.addPreset("工作", on: [screenA, screenB])
        rig.makeChain()
        XCTAssertNil(rig.chain.restorePreset(id: "gone", topologyKey: rig.key([screenA, screenB])))
        XCTAssertTrue(rig.restorer.snapshots.isEmpty)
        XCTAssertTrue(rig.spy.all.contains { $0.contains("result=no-preset") })
    }

    /// 防抖进行中被手动恢复抢占：挂起的判定作废，恢复结束后按当前拓扑重判（拓扑变化不丢）
    func testManualRestoreDuringDebounceRejudgesAfterwards() throws {
        let rig = try rig(start: [screenA, screenB])
        let two = try rig.addPreset("双屏", on: [screenA, screenB])
        try rig.addPreset("单屏", on: [screenA])
        rig.makeChain()

        rig.topology.set([screenA])
        rig.chain.screenParametersChanged()        // 拔屏事件，防抖中
        rig.topology.set([screenA, screenB])       // 用户随即插回并从提示点「恢复」
        rig.chain.restorePreset(id: two.id, topologyKey: rig.key([screenA, screenB]))
        rig.scheduler.runUntilIdle()

        XCTAssertEqual(rig.restorer.snapshots.map { $0.windows.first?.bundleID }, ["双屏", "双屏"],
                       "手动恢复后重判：快速拔插按拓扑变过判定 → 自动预设")
    }

    /// 恢复进行中再入手动入口：ignored 落日志、不二次恢复
    func testManualReentryWhileRestoringIsIgnored() throws {
        let rig = try rig(start: [screenA, screenB])
        let work = try rig.addPreset("工作", on: [screenA, screenB])
        let key = rig.key([screenA, screenB])
        rig.makeChain()
        rig.restorer.onRestore = { [rig] _ in rig.chain.restorePresetAsync(id: work.id, topologyKey: key) }

        rig.chain.restorePresetAsync(id: work.id, topologyKey: key)

        XCTAssertEqual(rig.restorer.snapshots.count, 1)
        XCTAssertEqual(triggerSteps(rig.spy.all).filter { $0 == "ignored" }.count, 1)
    }
}

// MARK: - 余震重放（spec §5.1 判据：插屏后 macOS 二次挪窗仍需兜底 → 保留，绑定同一预设）

/// 实测缺陷（11-03 08:42/08:43）：插屏后 macOS 2–6s 再发一次屏幕事件（拓扑不变）并重排窗口，
/// 覆盖刚完成的恢复。期望：自动恢复后的余震窗内，拓扑不变的 settle 用同一预设快照重放（保留回滚快照、不重复告知）。
final class TriggerChainAftershockTests: XCTestCase {
    private func makeRig() throws -> Rig {
        let rig = Rig(start: [screenA], dir: try makeTempDir())
        try rig.addPreset("工作", on: [screenA, screenB])
        rig.makeChain()
        rig.change(to: [screenA, screenB])  // 首轮自动恢复
        return rig
    }

    private func lateEvent(_ rig: Rig, after seconds: TimeInterval) {
        rig.clock.set(rig.clock.current.addingTimeInterval(seconds))
        rig.chain.screenParametersChanged()
        rig.scheduler.runUntilIdle()
    }

    func testAftershockWithinWindowReappliesSamePresetPreservingUndoWithoutSecondOutcome() throws {
        let rig = try makeRig()
        try rig.addPreset("后来存的", on: [screenA, screenB], auto: true)  // 重放绑定首轮预设，不跟随新自动
        let before = rig.spy.all.count

        lateEvent(rig, after: 2)

        XCTAssertEqual(rig.restorer.snapshots.map { $0.windows.first?.bundleID }, ["工作", "工作"])
        XCTAssertEqual(rig.restorer.preserveUndoFlags, [false, true], "重放不得覆盖首轮的回滚快照")
        XCTAssertEqual(rig.outcomes.items.count, 1, "重放不重复告知")
        let lines = Array(rig.spy.all.dropFirst(before))
        XCTAssertEqual(triggerSteps(lines), ["event", "debounce-settle", "aftershock-reapply", "space-stable",
                                             "restore-start", "restore-done"])
        let stamps = triggerTimestamps(lines)
        XCTAssertEqual(stamps[4].timeIntervalSince(stamps[0]), TriggerChainConstants.aftershockDebounceQuietPeriod,
                       accuracy: 0.001, "余震走短防抖，签名与上次开火一致即开火")
    }

    func testEventAfterWindowIsZeroAction() throws {
        let rig = try makeRig()
        lateEvent(rig, after: TriggerChainConstants.aftershockWindow + 5)
        XCTAssertEqual(rig.restorer.snapshots.count, 1, "余震窗外的拓扑不变事件零动作")
    }

    func testReapplyIsCappedPerRestore() throws {
        let rig = try makeRig()
        for _ in 0..<4 { lateEvent(rig, after: 1) }
        XCTAssertEqual(rig.restorer.snapshots.count, 1 + TriggerChainConstants.aftershockMaxReapplies)
    }

    /// 余震预判落空：事件时拓扑源尚未反映拔屏 → 补足普通防抖再判定
    func testMissedAftershockPredictionExtendsToNormalDebounce() throws {
        let rig = try makeRig()
        let before = rig.spy.all.count
        rig.clock.set(rig.clock.current.addingTimeInterval(1))
        rig.chain.screenParametersChanged()
        rig.topology.set([screenA])
        rig.scheduler.runUntilIdle()

        let lines = Array(rig.spy.all.dropFirst(before))
        XCTAssertEqual(Array(triggerSteps(lines).prefix(3)), ["event", "debounce-extend", "debounce-settle"])
        let stamps = triggerTimestamps(lines)
        XCTAssertEqual(stamps[2].timeIntervalSince(stamps[0]), TriggerChainConstants.debounceQuietPeriod, accuracy: 0.001)
        XCTAssertTrue(lines[2].contains("result=changed"))
    }

    func testTopologyChangeClearsAftershockState() throws {
        let rig = try makeRig()
        rig.clock.set(rig.clock.current.addingTimeInterval(1))
        rig.change(to: [screenA])   // 恢复后立刻拔屏（单屏无预设）
        rig.clock.set(rig.clock.current.addingTimeInterval(1))
        rig.change(to: [screenA])   // 拓扑不变事件：不得重放双屏预设
        XCTAssertEqual(rig.restorer.snapshots.count, 1)
    }

    /// 手动恢复作废余震记录（重放只兜底自动恢复）
    func testManualRestoreClearsAftershockState() throws {
        let rig = try makeRig()
        let preset = try XCTUnwrap(rig.store.topology(key: rig.key([screenA, screenB]))?.presets.first)
        rig.chain.restorePreset(id: preset.id, topologyKey: rig.key([screenA, screenB]))
        lateEvent(rig, after: 1)
        XCTAssertEqual(rig.restorer.snapshots.count, 2, "手动恢复后的拓扑不变事件零动作")
    }
}
