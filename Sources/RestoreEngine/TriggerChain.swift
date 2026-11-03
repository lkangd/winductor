import Core
import Foundation

// TriggerChain.swift — 触发链状态机（票 17，spec §6.2/§6.3）。
// 链路：屏幕参数变化事件 → 防抖静默期 1.5s（新事件重置计时）→ 当前屏幕 UUID 集合与某份快照
//（现势/历史）精确一致 → Space 列表连续两轮（间隔 500ms）不变 → 调 RestoreEngine.restore(snapshot:)
// 一次性恢复（单轮 best-effort，无重试循环）。
// 触发方向唯一：屏幕集合变大且精确匹配（spec §6.2）；集合变小（拔出 A4）只更新基线不干预；
// 集合不变（睡眠唤醒/锁屏解锁/分辨率微调，A2/A3）零动作——实现上只监听 didChangeScreenParameters。
// 可注入接缝（全部可 fake 测试）：时钟（TriggerClockProviding）、调度器（TriggerChainScheduling）、
// 屏幕源（displaysProvider）、Space 列表（SpaceListProviding）、恢复管线（SnapshotRestoring）、日志 sink。
// 结构化日志（[trigger] step=… at=…）：时间戳链证明 event → debounce-settle → topology-match
// → space-stable ×2 → restore-start（票面「日志时间戳链可证明」）。

/// 触发链硬编码常量（spec §10.3）
public enum TriggerChainConstants {
    /// 触发防抖静默期 1.5s（新事件重置计时，03 #4）
    public static let debounceQuietPeriod: TimeInterval = 1.5
    /// Space 稳定判据：两轮间隔 500ms（03 #4）
    public static let spaceStableInterval: TimeInterval = 0.5
    /// Space 稳定性采样总轮次上限（含不可用/变化重采）：SLS 长期不可用或 Space 持续抖动时
    /// 单轮放弃回 idle，防无限采样空转（恢复本身仍是一次性，不构成重试循环）
    public static let spaceStableMaxSamples = 6
}

/// 触发链时钟接缝（日志 at= 时间戳来源；测试注入虚拟时钟，生产 = 系统时钟）
public protocol TriggerClockProviding: Sendable {
    func now() -> Date
}

/// 时钟生产实现
public struct SystemTriggerClock: TriggerClockProviding {
    public init() {}
    public func now() -> Date { Date() }
}

/// 触发链调度接缝（防抖计时 / Space 稳定轮次定时；测试注入虚拟调度器逐点触发）
public protocol TriggerChainScheduling: Sendable {
    func schedule(after: TimeInterval, _ fire: @escaping @Sendable () -> Void)
    /// 取消全部挂起回调（防抖「新事件重置计时」即取消后重排）
    func cancelScheduled()
}

/// 调度生产实现：串行队列 asyncAfter + DispatchWorkItem 取消
public final class DispatchTriggerScheduler: TriggerChainScheduling {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: [DispatchWorkItem] = []

    public init(queue: DispatchQueue = DispatchQueue(label: "wlr.trigger-chain")) {
        self.queue = queue
    }

    public func schedule(after: TimeInterval, _ fire: @escaping @Sendable () -> Void) {
        lock.lock()
        let item = DispatchWorkItem(block: fire)
        pending.append(item)
        lock.unlock()
        queue.asyncAfter(deadline: .now() + after, execute: item)
    }

    public func cancelScheduled() {
        lock.lock()
        pending.forEach { $0.cancel() }
        pending.removeAll()
        lock.unlock()
    }
}

/// Space 列表信息源接缝（Space 稳定判据的对比来源；spec §6.2「经 SpaceProviding/快照对比」，此处走 SpaceProviding）
public protocol SpaceListProviding: Sendable {
    /// 规范形 Space 列表（每项 "displayUUID#index#kind"，排序后整体比较）；nil = 本轮不可用
    func spaceList() -> [String]?
}

/// Space 列表生产实现：包装 SpaceProviding（SpaceAdapter 的 SLSCopyManagedDisplaySpaces 展开）
public struct ManagedSpaceListProvider: SpaceListProviding {
    private let provider: SpaceProviding

    public init(_ provider: SpaceProviding) { self.provider = provider }

    public func spaceList() -> [String]? {
        guard let entries = try? provider.managedSpaces() else { return nil }
        return entries.map { "\($0.displayUUID)#\($0.index)#\($0.kind)" }.sorted()
    }
}

/// 恢复管线接缝：触发链只调一次性恢复入口（spec §6.3），测试注入 fake、生产 = RestoreEngine
public protocol SnapshotRestoring: Sendable {
    @discardableResult
    func restore(snapshot: Snapshot) throws -> RestoreReport
}

/// 生产接线：触发链直接驱动恢复引擎（restore(snapshot:) 即 §6.8 单轮管线）
extension RestoreEngine: SnapshotRestoring {}

/// 触发链状态机（票 19 接线：app 观察.didChangeScreenParametersNotification 后调
/// screenParametersChanged()；通知投递经 onNotice 接缝交给 Menubar）。
public final class TriggerChain: @unchecked Sendable {
    private enum Phase: Equatable {
        case idle, debouncing, stabilizing, restoring
    }

    private let store: SnapshotStore
    private let restorer: SnapshotRestoring
    /// nil = 无 Space 列表源（稳定判据采样不可用，走放弃上限）
    private let spaces: SpaceListProviding?
    private let displaysProvider: () -> [Displays.Info]
    private let clock: TriggerClockProviding
    private let scheduler: TriggerChainScheduling
    private let log: LogWriting?
    /// 与 RestoreEngine/SpaceAdapter 共用的 [degrade] 收集 sink（票 19 接线：同一个实例传给引擎）
    private let degradeCollector: DegradeCollectingLog?
    /// 手动异步入口的管线执行器（默认后台串行队列；菜单路径不阻塞主线程）
    private let restoreEnqueue: (@escaping @Sendable () -> Void) -> Void
    /// 拔屏前基线（shrank 时冻结）：回到该拓扑集合才允许自动恢复，且恢复源用冻结时的快照内容
    /// （实测缺陷：插回后 poller 会把 macOS 中间态重排写进 live 快照，恢复若在触发时现读
    /// 就是垃圾基线；中间态拓扑也可能精确命中过期快照触发全量垃圾恢复，如 2 屏键）
    private struct ReturnHome {
        let uuids: Set<String>
        let snapshot: Snapshot?
        let structure: Set<String>   // displayUUID#index#kind 集合（与运行时签名同构）
    }
    /// 按拓扑分键的冻结点（多段拔屏 3→2→1 时每段各冻结一份，后段不覆盖外层：
    /// 实测缺陷 11-03 03:54——单槽被第二段降级为 2 屏，插回 3 屏只能现读被 poller 中间态污染的 live-3）
    private var returnHomes: [Set<String>: ReturnHome] = [:]
    /// 本轮稳定判据是否要求签名与基线结构一致（持有基线内容时为真；防止 Space 重排未完成时开火）
    private var pendingHomeStructure: Set<String>?
    /// 通知投递接缝（票 19：接 UNUserNotificationCenter；测试收集断言）
    private let onNotice: @Sendable (RestoreNotice) -> Void

    // stateLock 保护以下状态；restore 期间的引擎调用在锁外执行（见 performRestore）
    private let stateLock = NSLock()
    private var phase: Phase = .idle
    /// 最近一次判定的屏幕 UUID 集合基线（链建立时初始化；每次 settle 后更新）
    private var settledUUIDs: Set<String> = []
    /// 防抖静默期内是否见过非基线拓扑（快速拔→插回的痕迹；settle 消费即清零）
    private var sawDivergenceDuringDebounce = false
    /// 恢复进行中到来过屏幕事件（被 ignored）：恢复结束后需重判拓扑（实测事故 11-03 07:39：
    /// 恢复中第三块屏接入被吞，3 屏恢复永不触发）
    private var eventDuringRestore = false
    /// 进行中的 Space 稳定判据目标集合（防抖被新事件重置后恢复判据用）
    private var stabilizationTarget: Set<String>?
    /// 稳定判据通过后待恢复的快照与拓扑键
    private var pendingMatch: (snapshot: Snapshot, key: String)?
    /// 连续一致采样轮次（变化后重计）
    private var consecutiveSamples = 0
    /// 采样总轮次（放弃上限用）
    private var totalSamples = 0
    /// 上一轮 Space 规范形签名
    private var lastSpaceSignature: [String]?

    /// [trigger] 行自带 at= 时间戳（ISO8601 带小数秒），时间戳链不依赖外层 sink 是否加戳
    private static let stampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 快照 Space 结构 → 与运行时签名同构的记号集合（displayUUID#index#kind；kind 对齐 SpaceEntry 的 0/4）
    static func structureSignature(from spaces: [SnapshotSpace]) -> Set<String> {
        Set(spaces.map { "\($0.displayUUID)#\($0.index)#\($0.kind == .fullscreen ? 4 : 0)" })
    }

    public init(store: SnapshotStore,
                restorer: SnapshotRestoring,
                spaces: SpaceListProviding?,
                displaysProvider: @escaping () -> [Displays.Info] = Displays.active,
                clock: TriggerClockProviding = SystemTriggerClock(),
                scheduler: TriggerChainScheduling = DispatchTriggerScheduler(),
                log: LogWriting? = nil,
                degradeCollector: DegradeCollectingLog? = nil,
                restoreEnqueue: @escaping (@escaping @Sendable () -> Void) -> Void = { work in
                    DispatchQueue(label: "wlr.restore", qos: .userInitiated).async(execute: work)
                },
                onNotice: @escaping @Sendable (RestoreNotice) -> Void = { _ in }) {
        self.store = store
        self.restorer = restorer
        self.spaces = spaces
        self.displaysProvider = displaysProvider
        self.clock = clock
        self.scheduler = scheduler
        self.log = log
        self.degradeCollector = degradeCollector
        self.restoreEnqueue = restoreEnqueue
        self.onNotice = onNotice
        // 基线：链建立时的屏幕集合（app 启动即建链；此后第一次插回事件即判「变大」）
        stateLock.lock()
        settledUUIDs = Set(displaysProvider().compactMap(\.uuid).filter { !$0.isEmpty })
        stateLock.unlock()
        log?.write(chainLine(step: "baseline", detail: "displays=\(settledUUIDs.count)"))
        seedReturnHomesAtLaunch()
    }

    /// 少屏状态下启动（拔屏开会时 app 重启 / 登录启动）：内存冻结点为空，插回时中间拓扑会精确命中
    /// 陈旧快照被当正常拓扑恢复（实测事故 11-03 07:39）。按磁盘上「当前集合的极大超集拓扑」重建冻结点：
    /// 当前缺屏 ⇒ 这些拓扑自拔屏后不可能被 poller 写过 = 拔屏前内容。非极大超集（如 3 屏的 2 屏子集）
    /// 不冻结 = 视为中间拓扑。
    private func seedReturnHomesAtLaunch() {
        let current = settledUUIDs
        guard !current.isEmpty else { return }
        let supersets = liveTopologies().filter { current.isSubset(of: $0) && $0.count > current.count }
        let maximal = supersets.filter { candidate in
            !supersets.contains { candidate.isSubset(of: $0) && $0.count > candidate.count }
        }
        for uuids in maximal {
            let key = SnapshotStore.topologyKey(forDisplayUUIDs: Array(uuids))
            let held = store.loadLive(topologyKey: key)
            stateLock.lock()
            returnHomes[uuids] = ReturnHome(uuids: uuids, snapshot: held,
                                            structure: held.map { Self.structureSignature(from: $0.spaces) } ?? [])
            stateLock.unlock()
            log?.write(chainLine(step: "baseline-hold", result: held == nil ? "miss" : "held",
                                 detail: "key=\(key) launch-seed"))
        }
    }

    /// 快照目录里 live- 文件反拆出的拓扑集合（键格式见 uuids(inTopologyKey:)）
    private func liveTopologies() -> [Set<String>] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: store.directory,
                                                                         includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { file -> Set<String>? in
            let name = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "json", name.hasPrefix("live-"),
                  let uuids = Self.uuids(inTopologyKey: String(name.dropFirst("live-".count))) else { return nil }
            return Set(uuids)
        }
    }

    /// 取消全部挂起回调（app 退出 / 测试清理）
    public func stop() {
        scheduler.cancelScheduled()
    }

    // MARK: - 事件入口

    /// 屏幕参数变化事件（生产：NSApplication.didChangeScreenParametersNotification 观察方，票 19 接线）。
    /// 睡眠唤醒/锁屏解锁/分辨率微调同样只经此入口——集合不变时零动作（A2/A3 反例的实现口径）。
    public func screenParametersChanged() {
        stateLock.lock()
        guard phase != .restoring else {
            eventDuringRestore = true
            stateLock.unlock()
            log?.write(chainLine(step: "ignored", detail: "restore-in-progress recheck-after"))
            return
        }
        // 防抖：新事件取消挂起回调、重排 1.5s 计时（spec §6.2 新事件重置）
        scheduler.cancelScheduled()
        phase = .debouncing
        // 快速拔插痕迹：静默期内见过非基线拓扑（拔出瞬间）。settle 时即使已回到基线，
        // 也按「回到基线拓扑」处理而非零动作——否则拔插循环被 A2/A3 分支误吞（11-03 实测）
        let currentAtEvent = Set(displaysProvider().compactMap(\.uuid).filter { !$0.isEmpty })
        if currentAtEvent != settledUUIDs { sawDivergenceDuringDebounce = true }
        log?.write(chainLine(step: "event", detail: "didChangeScreenParameters"))
        stateLock.unlock()
        scheduler.schedule(after: TriggerChainConstants.debounceQuietPeriod) { [weak self] in
            self?.settleTopology()
        }
    }

    // MARK: - 防抖静默期结束：拓扑判定

    private func settleTopology() {
        stateLock.lock()
        guard phase == .debouncing else {
            stateLock.unlock()
            return
        }
        let current = Set(displaysProvider().compactMap(\.uuid).filter { !$0.isEmpty })
        let baseline = settledUUIDs
        let sawDivergence = sawDivergenceDuringDebounce
        sawDivergenceDuringDebounce = false

        // 防抖静默期结束：先落 debounce-settle 行（时间戳链第 2 环），再按集合变化分岔。
        // resume=stability：稳定判据进行中来了新事件（插拔二段事件常见），
        // 防抖重置后回到稳定性采样；已采样轮次仍有效（Space 列表语义未变，
        // 恢复现场后下一轮凑满「连续两轮不变」即触发），不判零动作。
        let direction = current == baseline ? "unchanged" : (current.count < baseline.count ? "shrank" : "grew")
        let resumingStability = (current == baseline && stabilizationTarget != nil)
        log?.write(chainLine(step: "debounce-settle", result: direction,
                             detail: "baseline=\(baseline.count) current=\(current.count)"
                                 + (resumingStability ? " resume=stability" : "")))

        if current == baseline {
            if resumingStability {
                phase = .stabilizing
                stateLock.unlock()
                sampleSpaceStability()
                return
            }
            guard sawDivergence else {
                // 无拓扑变化事件（睡眠唤醒/锁屏解锁/分辨率微调）→ 零动作（spec §6.2，A2/A3）
                phase = .idle
                stateLock.unlock()
                return
            }
            // 快速拔→插回（同处静默期，插回事件重置了防抖）：按「回到基线拓扑」处理。
            // 补记 baseline-hold（该拓扑已有冻结点则保留更早的拔屏前内容，不现读覆盖）
            if returnHomes[baseline] == nil {
                let held = store.loadLive(topologyKey: SnapshotStore.topologyKey(forDisplayUUIDs: baseline.sorted()))
                returnHomes[baseline] = ReturnHome(
                    uuids: baseline,
                    snapshot: held,
                    structure: held.map { Self.structureSignature(from: $0.spaces) } ?? [])
                log?.write(chainLine(step: "baseline-hold", result: held == nil ? "miss" : "held",
                                     detail: "key=\(SnapshotStore.topologyKey(forDisplayUUIDs: baseline.sorted())) fast-replug"))
            }
            // 落到下方共用恢复路径（current==baseline 直达匹配段）
        }
        if current.count < baseline.count {
            // 拔出（集合变小）：只更新基线不干预（spec §6.2，A4）；
            // 同时冻结拔屏前基线（集合 + 快照内容 + Space 结构），回到该集合才自动恢复
            let held = store.loadLive(topologyKey: SnapshotStore.topologyKey(forDisplayUUIDs: baseline.sorted()))
            returnHomes[baseline] = ReturnHome(
                uuids: baseline,
                snapshot: held,
                structure: held.map { Self.structureSignature(from: $0.spaces) } ?? [])
            settledUUIDs = current
            stabilizationTarget = nil
            phase = .idle
            stateLock.unlock()
            log?.write(chainLine(step: "baseline-hold", result: held == nil ? "miss" : "held",
                                 detail: "key=\(SnapshotStore.topologyKey(forDisplayUUIDs: baseline.sorted()))"))
            return
        }

        // 集合变大 = 唯一自动触发方向（spec §6.2）；若与拔屏前基线不一致（插回中间态），
        // 即使精确命中某份过期快照也不自动恢复——等待回到基线拓扑（手动「立即恢复」不受限）
        settledUUIDs = current
        let key = SnapshotStore.topologyKey(forDisplayUUIDs: Array(current))
        var homeSnapshot: Snapshot?
        if !returnHomes.isEmpty {
            if let home = returnHomes[current] {
                // 回到某段拔屏前拓扑：恢复源用冻结内容（防触发时现读被 poller 重写的中间态）
                homeSnapshot = home.snapshot
            } else {
                // 插回 home 的超集（如 app 在 2 屏启动后接第 3 屏）：放行，快照源回退现存拓扑匹配
                let homeCounts = returnHomes.keys.map(\.count)
                let isSupersetOfHome = returnHomes.keys.contains { $0.isSubset(of: current) && current.count > $0.count }
                if !isSupersetOfHome {
                    phase = .idle
                    log?.write(chainLine(step: "return-home-guard", result: "skip",
                                         detail: "matched=\(key) home-displays=\(homeCounts.max() ?? 0) current-displays=\(current.count)"))
                    stateLock.unlock()
                    return
                }
                log?.write(chainLine(step: "return-home-guard", result: "pass",
                                     detail: "superset-of-home home=\(homeCounts.max() ?? 0) current=\(current.count)"))
            }
            // ⊆ current 的冻结点已被本次回归取代（下次拔屏重新冻结）；⊋ current 的外层冻结点保留待回归
            returnHomes = returnHomes.filter { !$0.key.isSubset(of: current) }
        }
        guard let snapshot = homeSnapshot ?? matchSnapshot(for: current, key: key) else {
            // 拓扑部分匹配（插回后仍少一屏）：不自动恢复（spec §6.2，A5；提示通知见 emitPartialTopology）
            phase = .idle
            log?.write(chainLine(step: "topology-match", result: "partial",
                                 detail: "key=\(key) baseline=\(baseline.count) current=\(current.count)"))
            stateLock.unlock()
            emitPartialTopology(currentDisplayCount: current.count)
            return
        }
        log?.write(chainLine(step: "topology-match", result: "exact",
                             detail: "key=\(key) baseline=\(baseline.count) current=\(current.count)"))
        // 结构门槛：恢复源快照自带 Space 结构时，稳定判据额外要求现场签名与之一致
        //（空 Space 记录无法验证，不设门槛）；防插回后 macOS Space 重排未完成时把窗口移进中间态
        let sourceStructure = Self.structureSignature(from: snapshot.spaces)
        pendingHomeStructure = sourceStructure.isEmpty ? nil : sourceStructure
        phase = .stabilizing
        stabilizationTarget = current
        pendingMatch = (snapshot, key)
        consecutiveSamples = 0
        totalSamples = 0
        lastSpaceSignature = nil
        stateLock.unlock()
        sampleSpaceStability()
    }

    /// 拓扑精确匹配：当前 UUID 集合 == 某份快照（现势/历史）的 UUID 集合（集合相等判定，方向无关此处）
    private func matchSnapshot(for uuids: Set<String>, key: String) -> Snapshot? {
        guard !uuids.isEmpty, let snapshot = store.loadLive(topologyKey: key) else { return nil }
        // 键即 UUID 集合；再核对快照内容的集合相等（spec §6.2 集合相等判定）
        guard Set(snapshot.topology.map(\.uuid)) == uuids else { return nil }
        return snapshot
    }

    // MARK: - Space 稳定判据（连续两轮不变，间隔 500ms，spec §10.3）

    private func sampleSpaceStability() {
        stateLock.lock()
        guard phase == .stabilizing, let pending = pendingMatch else {
            stateLock.unlock()
            return
        }
        let round = consecutiveSamples + 1
        totalSamples += 1
        let atCap = totalSamples >= TriggerChainConstants.spaceStableMaxSamples
        guard let signature = spaces?.spaceList() else {
            if atCap {
                // Space 列表长期不可用：单轮放弃回 idle（防采样空转；不构成恢复重试）
                phase = .idle
                stabilizationTarget = nil
                pendingMatch = nil
                log?.write(chainLine(step: "space-stable", result: "give-up", round: round,
                                     detail: "space-list-unavailable"))
                stateLock.unlock()
                return
            }
            consecutiveSamples = 0
            log?.write(chainLine(step: "space-stable", result: "unavailable", round: round, detail: "-"))
            stateLock.unlock()
            scheduleNextSpaceSample()
            return
        }
        // 显示器几何纳入稳定判据（实测缺陷：插线后显示器全局排列（CG bounds）仍在重排，
        // L1 按中间态 bounds 写全局坐标 → 布局稳定后窗口集体偏移、左缘露壁纸）：
        // 总签名 = Space 列表 + 各屏全局几何，两轮一致才开火
        let displaySignature = displaysProvider()
            .map { "\($0.uuid)#\(Int($0.bounds.minX)),\(Int($0.bounds.minY)),\(Int($0.bounds.width))x\(Int($0.bounds.height))" }
            .sorted()
            .joined(separator: ",")
        let stableSignature = signature + [displaySignature]
        let signatureText = signature.joined(separator: ",")
        let isFirstSample = (lastSpaceSignature == nil)
        let matchesPrevious = (lastSpaceSignature == stableSignature)
        // 结构门槛：持有拔屏前基线时，除连续两轮一致外还要求 Space 结构与基线一致——
        // 插回后 macOS 重排 Space 需要数十秒，过早开火会把窗口移进重排中间态（实测缺陷）
        let structureReady = pendingHomeStructure == nil || Set(signature) == pendingHomeStructure
        // 连续一致计数：与上一轮一致 +1，变化重计为 1；达到 2 即「连续两轮不变」
        let roundNow = matchesPrevious ? round : 1
        consecutiveSamples = roundNow
        lastSpaceSignature = stableSignature

        if matchesPrevious && roundNow >= 2 && structureReady {
            // 连续两轮不变（且结构与基线一致）→ 触发一次性恢复（spec §6.2 → §6.3，无重试循环）
            let snapshot = pending.snapshot
            let key = pending.key
            log?.write(chainLine(step: "space-stable", result: "stable", round: roundNow,
                                 detail: "signature=\(signatureText)"))
            stabilizationTarget = nil
            pendingMatch = nil
            pendingHomeStructure = nil
            stateLock.unlock()
            if let notice = performRestore(trigger: .auto, snapshot: snapshot, key: key) {
                deliver(notice)
            }
            return
        }
        if atCap {
            // Space 持续抖动/不可用超上限：放弃本轮（回 idle；下一次屏幕事件重新走链）
            phase = .idle
            stabilizationTarget = nil
            pendingMatch = nil
            pendingHomeStructure = nil
            log?.write(chainLine(step: "space-stable", result: "give-up", round: roundNow,
                                 detail: "signature=\(signatureText) churning"))
            stateLock.unlock()
            return
        }
        let outcome = (matchesPrevious || isFirstSample) ? (structureReady ? "sampled" : "structure-changed") : "changed"
        log?.write(chainLine(step: "space-stable", result: outcome, round: roundNow,
                             detail: "signature=\(signatureText)"))
        stateLock.unlock()
        scheduleNextSpaceSample()
    }

    private func scheduleNextSpaceSample() {
        scheduler.schedule(after: TriggerChainConstants.spaceStableInterval) { [weak self] in
            self?.sampleSpaceStability()
        }
    }

    // MARK: - 一次性恢复（spec §6.3 单轮 best-effort）

    /// 调恢复引擎单轮管线（§6.8）；结束产出完成通知（§8.5 计数 + [degrade] 附注汇总）。
    /// 返回 nil = 当时已在恢复中（busy，记 ignored 日志）。
    private func performRestore(trigger: RestoreTriggerKind, snapshot: Snapshot, key: String) -> RestoreNotice? {
        stateLock.lock()
        guard phase != .restoring else {
            stateLock.unlock()
            log?.write(chainLine(step: "ignored", detail: "restore-in-progress"))
            return nil
        }
        phase = .restoring
        log?.write(chainLine(step: "restore-start", detail: "trigger=\(trigger.rawValue) key=\(key)"))
        let restorer = self.restorer
        stateLock.unlock()

        // 引擎调用在锁外：恢复可持续数秒（全屏动画等待等），期间事件入口记 ignored 不阻塞
        var report: RestoreReport?
        var failure: Error?
        do { report = try restorer.restore(snapshot: snapshot) } catch { failure = error }

        stateLock.lock()
        var degradedNames: [String] = []
        if let collector = degradeCollector {
            degradedNames = collector.drainDegradeLayers().map { RestoreNoticeLayers.name(forDegradeLayer: $0) }
        }
        phase = .idle
        let recheck = eventDuringRestore
        eventDuringRestore = false
        stateLock.unlock()
        // 恢复期间来过屏幕事件：按一次新事件重走防抖 → 拓扑判定（settledUUIDs 仍是本轮恢复的集合）
        if recheck { screenParametersChanged() }

        if let report {
            log?.write(chainLine(step: "restore-done",
                                 detail: "trigger=\(trigger.rawValue) ok=\(report.okCount) skip=\(report.skipCount) fail=\(report.failCount)"))
            return .completed(RestoreCompletionNotice(
                trigger: trigger, okCount: report.okCount, skipCount: report.skipCount,
                failCount: report.failCount, degradedLayerNames: degradedNames, failureDetail: nil))
        }
        let why = String(describing: failure ?? RestoreEngineError.noActiveDisplay)
        log?.write(chainLine(step: "restore-failed", detail: "trigger=\(trigger.rawValue) error=\(why)"))
        return .completed(RestoreCompletionNotice(
            trigger: trigger, okCount: 0, skipCount: 0, failCount: 0,
            degradedLayerNames: degradedNames, failureDetail: why))
    }

    // MARK: - 手动「立即恢复」（A6：跳过方向判定直接恢复，与自动触发共用管线）

    /// 手动重试入口（菜单「立即恢复」的管线级形态，03 #8；DebugCLI restore-now 为命令级形态）。
    /// - explicit 非空：不查快照目录，直接恢复该快照（restore-now <snapshot路径>）。
    /// - explicit 为空：按当前屏幕集合选快照——精确一致优先；否则取重叠最多的快照 best-effort
    ///   （部分拓扑 A5 场景的手动出口，spec §6.2/03 #8）。无候选返回 nil。
    /// 返回完成通知（与自动触发同结构）；无快照/忙时返回 nil。
    @discardableResult
    public func restoreNow(snapshot explicit: Snapshot? = nil) -> RestoreNotice? {
        if let explicit {
            let key = SnapshotStore.topologyKey(forDisplayUUIDs: explicit.topology.map(\.uuid))
            guard let notice = performRestore(trigger: .manual, snapshot: explicit, key: key) else { return nil }
            deliver(notice)
            return notice
        }
        guard let selected = selectManualSnapshot() else { return nil }
        guard let notice = performRestore(trigger: .manual, snapshot: selected.snapshot, key: selected.key) else {
            return nil
        }
        deliver(notice)
        return notice
    }

    /// 手动「立即恢复」异步形态（菜单路径）：快照选择仍在调用线程（毫秒级目录扫描），
    /// 恢复管线经 restoreEnqueue 离开调用线程（主线程不阻塞，修复 2 屏拓扑点立即恢复卡死数分钟的缺陷）；
    /// 完成通知照常投递（handle(notice:) 自带主线程汇编，后台线程投递安全）。
    public func restoreNowAsync(snapshot explicit: Snapshot? = nil) {
        if let explicit {
            let key = SnapshotStore.topologyKey(forDisplayUUIDs: explicit.topology.map(\.uuid))
            restoreEnqueue { [weak self] in
                guard let self,
                      let notice = self.performRestore(trigger: .manual, snapshot: explicit, key: key) else { return }
                self.deliver(notice)
            }
            return
        }
        guard let selected = selectManualSnapshot() else { return }
        restoreEnqueue { [weak self] in
            guard let self,
                  let notice = self.performRestore(trigger: .manual, snapshot: selected.snapshot, key: selected.key) else { return }
            self.deliver(notice)
        }
    }

    /// 手动形态共用：按当前屏幕集合选快照（精确一致 → best-effort 超集；含对应 [trigger] 日志行与忙守卫）
    private func selectManualSnapshot() -> (snapshot: Snapshot, key: String)? {
        let current = Set(displaysProvider().compactMap(\.uuid).filter { !$0.isEmpty })
        stateLock.lock()
        guard phase != .restoring else {
            stateLock.unlock()
            log?.write(chainLine(step: "ignored", detail: "restore-in-progress"))
            return nil
        }
        stateLock.unlock()
        let key = SnapshotStore.topologyKey(forDisplayUUIDs: Array(current))
        if let snapshot = matchSnapshot(for: current, key: key) {
            log?.write(chainLine(step: "topology-match", result: "exact", detail: "key=\(key) trigger=manual"))
            return (snapshot, key)
        }
        if let bestEffort = bestEffortSnapshot(for: current) {
            // 部分拓扑（A5）的手动出口：重叠最多的超集快照 best-effort（引擎对缺失屏条目 skip）
            log?.write(chainLine(step: "topology-match", result: "best-effort",
                                 detail: "key=\(bestEffort.key) trigger=manual"))
            return (bestEffort.snapshot, bestEffort.key)
        }
        log?.write(chainLine(step: "topology-match", result: "no-snapshot", detail: "key=\(key) trigger=manual"))
        return nil
    }

    /// 部分拓扑的 best-effort 快照选取：与当前集合重叠最多者优先；并列取屏幕更少，再字典序拓扑键。
    /// 候选 = 快照目录里 live-/history- 文件反拆出的拓扑键（键即 UUID 集合）。
    private func bestEffortSnapshot(for current: Set<String>) -> (snapshot: Snapshot, key: String)? {
        guard !current.isEmpty else { return nil }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        var candidates: [(key: String, uuids: [String])] = []
        for file in files where file.pathExtension == "json" {
            let name = file.deletingPathExtension().lastPathComponent
            let key: String?
            if name.hasPrefix("live-") {
                key = String(name.dropFirst("live-".count))
            } else if name.hasPrefix("history-") {
                // history-<slot>-<拓扑键>：去掉前缀与 slot 段
                let rest = name.dropFirst("history-".count)
                guard let dash = rest.firstIndex(of: "-") else { continue }
                key = String(rest[rest.index(after: dash)...])
            } else { continue }
            guard let k = key, let uuids = Self.uuids(inTopologyKey: k) else { continue }
            candidates.append((k, uuids))
        }
        // 重叠最多 → 屏幕更少 → 键字典序
        let ranked = candidates.sorted { a, b in
            let overlapA = a.uuids.filter { current.contains($0) }.count
            let overlapB = b.uuids.filter { current.contains($0) }.count
            if overlapA != overlapB { return overlapA > overlapB }
            if a.uuids.count != b.uuids.count { return a.uuids.count < b.uuids.count }
            return a.key < b.key
        }
        for candidate in ranked {
            if candidate.uuids.filter({ current.contains($0) }).isEmpty { break }  // 后面重叠只会更少
            if let snapshot = store.loadLive(topologyKey: candidate.key) {
                return (snapshot, candidate.key)
            }
        }
        return nil
    }

    /// 拓扑键反拆 UUID 集合：键 = 36 字符 UUID 段（段内含连字符）以 "-" 连接，段长恒定可无歧义反拆
    ///（SnapshotStore 文件头注释冻结的格式）
    static func uuids(inTopologyKey key: String) -> [String]? {
        let segments = (key.count + 1) / 37
        guard segments >= 1, key.count == segments * 37 - 1 else { return nil }
        var uuids: [String] = []
        var index = key.startIndex
        for i in 0..<segments {
            if i > 0 {
                guard key[index] == "-" else { return nil }
                index = key.index(after: index)
            }
            guard let end = key.index(index, offsetBy: 36, limitedBy: key.endIndex) else {
                return nil
            }
            uuids.append(String(key[index..<end]))
            index = end
        }
        return uuids
    }

    // MARK: - 通知与日志

    /// 通知投递（票 19 接系统通知）；每条通知都落 notify 日志行，链路到此收束
    private func deliver(_ notice: RestoreNotice) {
        log?.write(chainLine(step: "notify", kind: notice.kind, detail: notice.title))
        onNotice(notice)
    }

    /// A5 部分拓扑提示通知（spec §6.2；投递归票 19，此处只产出结构）
    private func emitPartialTopology(currentDisplayCount: Int) {
        deliver(.partialTopology(PartialTopologyNotice(currentDisplayCount: currentDisplayCount)))
    }

    /// [trigger] 结构化日志行（at= 由注入时钟提供，时间戳链可证明）
    private func chainLine(step: String, result: String? = nil, round: Int? = nil,
                           kind: String? = nil, detail: String? = nil) -> String {
        var line = "[trigger] step=\(step) at=\(Self.stampFormatter.string(from: clock.now()))"
        if let result { line += " result=\(result)" }
        if let round { line += " round=\(round)" }
        if let kind { line += " kind=\(kind)" }
        if let detail { line += " detail=\(detail)" }
        return line
    }
}
