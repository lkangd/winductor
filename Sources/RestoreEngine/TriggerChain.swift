import Core
import Foundation

// TriggerChain.swift — 触发链状态机（票 17 起步；display-presets 票 04 改为按预设判定，spec §5.1）。
// 链路：屏幕参数变化事件 → 防抖静默期 1.5s（新事件重置计时）→ Space 列表连续两轮（间隔 500ms）不变
// → 计算当前拓扑（TopologyIdentity：UUID 集合 + 邻接排列 + 旋转）→ 判定表：
//   未就绪 / 镜像中 → 零动作；拓扑无预设 → 零动作（并要求收起恢复提示）；
//   有自动预设 → 直接恢复（RestoreEngine 一次性管线）→ 记录最近恢复 → 自动恢复告知；
//   有预设无自动 → 请求恢复提示。判定结果经 onOutcome 接缝交给菜单栏 UI（票 05）。
// 不区分集合变大/变小（拔到单屏也判定）；拓扑未变的事件（睡眠唤醒/锁屏/分辨率调整）零动作；应用启动不判定。
// 恢复进行中拓扑变了：经 RestoreCancellation 协作式中止本轮（已移动窗口不回滚），恢复结束后按新拓扑重判。
// 余震重放（自动恢复后 10s 内拓扑不变的事件）保留：macOS 插屏后 2–6s 二次发事件并重排窗口与触发口径无关，
// 新链路照样会被覆盖；重放绑定同一预设快照、保留回滚快照、不重复告知。
// 可注入接缝（全部可 fake 测试）：时钟、调度器、拓扑源（topologyProvider）、就绪门（readiness）、
// Space 列表（SpaceListProviding）、恢复管线（SnapshotRestoring）、预设存储（PresetStore）、日志 sink。
// 结构化日志（[trigger] step=… at=…）：时间戳链证明 event → debounce-settle → space-stable ×2
// → topology-match → restore-start → restore-done → outcome。

/// 触发链硬编码常量（spec §10.3）
public enum TriggerChainConstants {
    /// 触发防抖静默期 1.5s（新事件重置计时，03 #4）
    public static let debounceQuietPeriod: TimeInterval = 1.5
    /// Space 稳定判据：两轮间隔 500ms（03 #4）
    public static let spaceStableInterval: TimeInterval = 0.5
    /// Space 稳定性采样总轮次上限（含不可用/变化重采）：SLS 长期不可用或 Space 持续抖动时
    /// 单轮放弃回 idle，防无限采样空转（恢复本身仍是一次性，不构成重试循环）
    public static let spaceStableMaxSamples = 6
    /// 余震窗（秒）：自动恢复结束后此窗内的「拓扑不变」settle 视为插屏余震，用同一预设快照重放恢复。
    /// 实测 macOS 插回末屏后 2–6s 还会再发一次屏幕事件并重排窗口（11-03），提速后恢复先于余震结束
    public static let aftershockWindow: TimeInterval = 10
    /// 单次自动恢复的余震重放上限（不构成重试循环）
    public static let aftershockMaxReapplies = 2
    /// 余震重放的防抖静默期（秒）：事件到达时即可预判为余震（窗内、拓扑 == 上次自动恢复拓扑、无拔插痕迹），
    /// 不必等普通插拔的 1.5s——实测 09:28 余震打乱窗口到重放纠正 2.7s 中 1.5s 是防抖
    public static let aftershockDebounceQuietPeriod: TimeInterval = 0.5
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

    public init(queue: DispatchQueue = DispatchQueue(label: "winductor.trigger-chain")) {
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
    /// preserveUndo = true：不重写回滚快照（余震重放用——此刻实况是被余震打乱的恢复结果，
    /// 覆盖会让「撤销」回到乱序态而非恢复前）。协议 requirement：existential 动态分派到实现
    @discardableResult
    func restore(snapshot: Snapshot, preserveUndo: Bool) throws -> RestoreReport
    /// cancellation = 协作式取消令牌（触发链在恢复中拓扑变化时 cancel；票 04）。协议 requirement：
    /// 装饰器（菜单栏图标）须转发，否则令牌在 existential 默认实现处丢失
    @discardableResult
    func restore(snapshot: Snapshot, preserveUndo: Bool, cancellation: RestoreCancellation?) throws -> RestoreReport
}

public extension SnapshotRestoring {
    /// 默认：不支持保留回滚快照的实现按普通恢复处理
    @discardableResult
    func restore(snapshot: Snapshot, preserveUndo: Bool) throws -> RestoreReport {
        try restore(snapshot: snapshot)
    }

    /// 默认：不支持取消的实现忽略令牌（整轮跑完）
    @discardableResult
    func restore(snapshot: Snapshot, preserveUndo: Bool, cancellation: RestoreCancellation?) throws -> RestoreReport {
        try restore(snapshot: snapshot, preserveUndo: preserveUndo)
    }
}

/// 生产接线：触发链直接驱动恢复引擎（restore(snapshot:) 即 §6.8 单轮管线）
extension RestoreEngine: SnapshotRestoring {}

/// 触发链状态机（app 观察 didChangeScreenParametersNotification 后调 screenParametersChanged()；
/// 判定结果经 onOutcome、手动恢复完成通知经 onNotice 交给 Menubar）。
public final class TriggerChain: @unchecked Sendable {
    private enum Phase: Equatable {
        case idle, debouncing, stabilizing, restoring
    }

    /// 「拓扑是否变了」的比较单位：身份键 + 镜像标记（分辨率/偏移/主屏不参与，spec §3.1）
    private struct TopologyState: Equatable {
        let key: String
        let isMirrored: Bool
        let displayCount: Int

        init(_ observed: ObservedTopology) {
            key = observed.identity.key
            isMirrored = observed.isMirrored
            displayCount = observed.displays.count
        }
    }

    /// 最近一次自动恢复（余震重放来源：绑定同一预设快照；拓扑变化、手动恢复、中止即作废）
    private struct AutoRestoreRecord {
        let presetID: String
        let key: String
        let snapshot: Snapshot
        let doneAt: Date
        var reapplies: Int
        /// 开火时的稳定签名（Space 列表 + 各屏几何）：余震后首轮采样与之一致即视为已稳定
        let stableSignature: [String]?
    }

    /// 稳定判据通过后的判定动作（stateLock 内算出，锁外执行）
    private enum Decision {
        case outcome(TriggerOutcome)
        case autoRestore(preset: Preset, topology: PresetTopology, cancellation: RestoreCancellation)
    }

    private let presets: PresetStore
    private let restorer: SnapshotRestoring
    /// nil = 无 Space 列表源（稳定判据采样不可用，走放弃上限）
    private let spaces: SpaceListProviding?
    private let topologyProvider: () -> ObservedTopology
    /// 未就绪门（授权未齐 = 零动作；生产 = PermissionMonitor.status.isReady）
    private let readiness: () -> Bool
    private let clock: TriggerClockProviding
    private let scheduler: TriggerChainScheduling
    private let log: LogWriting?
    /// 与 RestoreEngine/SpaceAdapter 共用的 [degrade] 收集 sink（同一个实例传给引擎）
    private let degradeCollector: DegradeCollectingLog?
    /// 手动异步入口的管线执行器（默认后台串行队列；菜单/提示路径不阻塞主线程）
    private let restoreEnqueue: (@escaping @Sendable () -> Void) -> Void
    /// 手动恢复完成通知（系统通知投递；自动恢复的告知走 onOutcome）
    private let onNotice: @Sendable (RestoreNotice) -> Void
    /// 判定结果接缝（票 05 恢复提示 / 自动恢复告知 popover 挂这里）
    private let onOutcome: @Sendable (TriggerOutcome) -> Void

    // stateLock 保护以下状态；恢复引擎调用在锁外执行（见 runRestore）
    private let stateLock = NSLock()
    private var phase: Phase = .idle
    /// 最近一次判定（或链建立时）的拓扑基线
    private var settled: TopologyState
    /// 防抖静默期内是否见过非基线拓扑（快速拔→插回的痕迹；settle 消费即清零）
    private var sawDivergenceDuringDebounce = false
    /// 恢复进行中到来过屏幕事件：恢复结束后重走防抖 → 判定
    private var eventDuringRestore = false
    /// 进行中恢复的取消令牌与拓扑键（恢复中拓扑变化即 cancel）
    private var activeRestore: (cancellation: RestoreCancellation, key: String)?
    /// Space 稳定判据进行中（防抖被新事件重置后，拓扑未变则回到采样）
    private var stabilizationPending = false
    /// 本轮稳定判据通过后执行余震重放（nil = 正常判定）
    private var pendingReapply: AutoRestoreRecord?
    /// 连续一致采样轮次（变化后重计）
    private var consecutiveSamples = 0
    /// 采样总轮次（放弃上限用）
    private var totalSamples = 0
    /// 上一轮稳定签名
    private var lastSpaceSignature: [String]?
    private var lastAutoRestore: AutoRestoreRecord?
    /// 本次防抖按余震预判走了短静默期（settle 时预判落空则补足普通静默期）
    private var debouncedAsAftershock = false

    /// [trigger] 行自带 at= 时间戳（ISO8601 带小数秒），时间戳链不依赖外层 sink 是否加戳
    private static let stampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(presets: PresetStore,
                restorer: SnapshotRestoring,
                spaces: SpaceListProviding?,
                topologyProvider: @escaping () -> ObservedTopology = ObservedTopology.current,
                readiness: @escaping () -> Bool = { true },
                clock: TriggerClockProviding = SystemTriggerClock(),
                scheduler: TriggerChainScheduling = DispatchTriggerScheduler(),
                log: LogWriting? = nil,
                degradeCollector: DegradeCollectingLog? = nil,
                restoreEnqueue: @escaping (@escaping @Sendable () -> Void) -> Void = { work in
                    DispatchQueue(label: "winductor.restore", qos: .userInitiated).async(execute: work)
                },
                onNotice: @escaping @Sendable (RestoreNotice) -> Void = { _ in },
                onOutcome: @escaping @Sendable (TriggerOutcome) -> Void = { _ in }) {
        self.presets = presets
        self.restorer = restorer
        self.spaces = spaces
        self.topologyProvider = topologyProvider
        self.readiness = readiness
        self.clock = clock
        self.scheduler = scheduler
        self.log = log
        self.degradeCollector = degradeCollector
        self.restoreEnqueue = restoreEnqueue
        self.onNotice = onNotice
        self.onOutcome = onOutcome
        // 基线：链建立时的拓扑（应用启动不判定，spec §5.1；此后第一次拓扑变化才判定）
        settled = TopologyState(topologyProvider())
        log?.write(chainLine(step: "baseline", detail: "displays=\(settled.displayCount) key=\(settled.key)"))
    }

    /// 取消全部挂起回调（app 退出 / 测试清理）
    public func stop() {
        scheduler.cancelScheduled()
    }

    // MARK: - 事件入口

    /// 屏幕参数变化事件（生产：NSApplication.didChangeScreenParametersNotification 观察方）。
    /// 睡眠唤醒/锁屏解锁/分辨率调整同样只经此入口——拓扑不变时零动作。
    public func screenParametersChanged() {
        stateLock.lock()
        let current = TopologyState(topologyProvider())
        if phase == .restoring {
            eventDuringRestore = true
            if let active = activeRestore, current.key != active.key || current.isMirrored {
                // 恢复进行中拓扑变了：协作式中止本轮（已移动窗口不回滚），恢复结束后按新拓扑重判
                active.cancellation.cancel()
                log?.write(chainLine(step: "restore-cancel", result: "topology-changed",
                                     detail: "from=\(active.key) to=\(current.key) recheck-after"))
            } else {
                log?.write(chainLine(step: "ignored", detail: "restore-in-progress recheck-after"))
            }
            stateLock.unlock()
            return
        }
        // 防抖：新事件取消挂起回调、重排 1.5s 计时（新事件重置）
        scheduler.cancelScheduled()
        phase = .debouncing
        // 快速拔插痕迹：静默期内见过非基线拓扑。settle 时即使已回到基线也按「拓扑变过」判定
        if current != settled { sawDivergenceDuringDebounce = true }
        // 事件到达即按 settle 的余震判据预判（判据不成立的事件仍走普通 1.5s 防抖）
        let asAftershock = !sawDivergenceDuringDebounce && aftershockCandidate(current: current) != nil
        debouncedAsAftershock = asAftershock
        log?.write(chainLine(step: "event", detail: "didChangeScreenParameters"))
        // 锁内排程：并发事件入口不得让被取消的旧短防抖在新事件的取消之后才排上
        scheduler.schedule(after: asAftershock
                               ? TriggerChainConstants.aftershockDebounceQuietPeriod
                               : TriggerChainConstants.debounceQuietPeriod) { [weak self] in
            self?.settleTopology()
        }
        stateLock.unlock()
    }

    /// 余震判据（调用方持 stateLock）：自动恢复刚结束（窗内）、拓扑未变、重放额度未用尽
    private func aftershockCandidate(current: TopologyState) -> AutoRestoreRecord? {
        guard let last = lastAutoRestore, last.key == current.key, !current.isMirrored,
              clock.now().timeIntervalSince(last.doneAt) <= TriggerChainConstants.aftershockWindow,
              last.reapplies < TriggerChainConstants.aftershockMaxReapplies else { return nil }
        return last
    }

    // MARK: - 防抖静默期结束：拓扑是否变了

    private func settleTopology() {
        stateLock.lock()
        guard phase == .debouncing else {
            stateLock.unlock()
            return
        }
        let current = TopologyState(topologyProvider())
        if debouncedAsAftershock {
            debouncedAsAftershock = false
            if current != settled || sawDivergenceDuringDebounce || aftershockCandidate(current: current) == nil {
                // 余震预判落空（事件时拓扑源尚未反映变化）：补足普通静默期再判定，普通拔插时序不变
                log?.write(chainLine(step: "debounce-extend", detail: "aftershock-prediction-missed"))
                scheduler.schedule(after: TriggerChainConstants.debounceQuietPeriod
                                       - TriggerChainConstants.aftershockDebounceQuietPeriod) { [weak self] in
                    self?.settleTopology()
                }
                stateLock.unlock()
                return
            }
        }
        let changed = current != settled || sawDivergenceDuringDebounce
        sawDivergenceDuringDebounce = false
        // resume=stability：稳定判据进行中来了拓扑不变的新事件（插拔二段事件常见），回到采样继续
        let resuming = !changed && stabilizationPending
        log?.write(chainLine(step: "debounce-settle", result: changed ? "changed" : "unchanged",
                             detail: "displays=\(current.displayCount) key=\(current.key)"
                                 + (resuming ? " resume=stability" : "")))
        if changed {
            settled = current
            lastAutoRestore = nil
            beginStabilization(reapply: nil)
        } else if resuming {
            phase = .stabilizing
        } else if var last = aftershockCandidate(current: current) {
            // 插屏余震：自动恢复刚结束，macOS 又发拓扑不变的屏幕事件并重排窗口 → 同一预设快照重放
            last.reapplies += 1
            lastAutoRestore = last
            log?.write(chainLine(step: "aftershock-reapply", result: "scheduled",
                                 detail: "key=\(last.key) preset=\(last.presetID) "
                                     + "reapply=\(last.reapplies)/\(TriggerChainConstants.aftershockMaxReapplies)"))
            beginStabilization(reapply: last)
        } else {
            // 拓扑未变（睡眠唤醒/锁屏解锁/分辨率调整）→ 零动作
            phase = .idle
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        sampleSpaceStability()
    }

    /// 进入 Space 稳定判据（调用方持 stateLock）。余震重放以上次开火签名为第 1 轮：
    /// 首轮采样仍一致即开火（余震没改 Space/屏幕排列），不一致按「变化」重计
    private func beginStabilization(reapply: AutoRestoreRecord?) {
        phase = .stabilizing
        stabilizationPending = true
        pendingReapply = reapply
        totalSamples = 0
        lastSpaceSignature = reapply?.stableSignature
        consecutiveSamples = lastSpaceSignature == nil ? 0 : 1
    }

    // MARK: - Space 稳定判据（连续两轮不变，间隔 500ms）

    private func sampleSpaceStability() {
        stateLock.lock()
        guard phase == .stabilizing else {
            stateLock.unlock()
            return
        }
        let round = consecutiveSamples + 1
        totalSamples += 1
        let atCap = totalSamples >= TriggerChainConstants.spaceStableMaxSamples
        guard let signature = spaces?.spaceList() else {
            if atCap {
                // Space 列表长期不可用：单轮放弃回 idle（防采样空转；不构成恢复重试）
                abandonStabilization()
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
        // 显示器几何纳入稳定判据（实测缺陷：插线后全局排列仍在重排，L1 按中间态 bounds 写坐标 → 集体偏移）
        let displaySignature = topologyProvider().displays
            .map { "\($0.uuid)#\(Int($0.frame.x)),\(Int($0.frame.y)),\(Int($0.frame.w))x\(Int($0.frame.h))" }
            .sorted()
            .joined(separator: ",")
        let stableSignature = signature + [displaySignature]
        let signatureText = signature.joined(separator: ",")
        let isFirstSample = (lastSpaceSignature == nil)
        let matchesPrevious = (lastSpaceSignature == stableSignature)
        let roundNow = matchesPrevious ? round : 1
        consecutiveSamples = roundNow
        lastSpaceSignature = stableSignature

        if matchesPrevious && roundNow >= 2 {
            log?.write(chainLine(step: "space-stable", result: "stable", round: roundNow,
                                 detail: "signature=\(signatureText)"))
            stabilizationPending = false
            let reapply = pendingReapply
            pendingReapply = nil
            if let reapply {
                let cancellation = claimRestoreLocked(key: reapply.key)
                stateLock.unlock()
                // 重放：保留回滚快照（undo 仍指向首轮恢复前），不重复告知、不重复记录最近恢复
                _ = runRestore(trigger: .auto, snapshot: reapply.snapshot, key: reapply.key,
                               presetID: reapply.presetID, cancellation: cancellation,
                               reapply: true, stableSignature: stableSignature)
                return
            }
            let decision = decideLocked()
            stateLock.unlock()
            execute(decision, stableSignature: stableSignature)
            return
        }
        if atCap {
            // Space 持续抖动超上限：放弃本轮（回 idle；下一次屏幕事件重新走链）
            abandonStabilization()
            log?.write(chainLine(step: "space-stable", result: "give-up", round: roundNow,
                                 detail: "signature=\(signatureText) churning"))
            stateLock.unlock()
            return
        }
        let outcome = (matchesPrevious || isFirstSample) ? "sampled" : "changed"
        log?.write(chainLine(step: "space-stable", result: outcome, round: roundNow,
                             detail: "signature=\(signatureText)"))
        stateLock.unlock()
        scheduleNextSpaceSample()
    }

    /// 调用方持 stateLock
    private func abandonStabilization() {
        phase = .idle
        stabilizationPending = false
        pendingReapply = nil
    }

    private func scheduleNextSpaceSample() {
        scheduler.schedule(after: TriggerChainConstants.spaceStableInterval) { [weak self] in
            self?.sampleSpaceStability()
        }
    }

    // MARK: - 判定表（spec §5.1）

    /// 稳定后计算当前拓扑并查预设（调用方持 stateLock；有自动预设时在锁内占住恢复相位）
    private func decideLocked() -> Decision {
        let observed = topologyProvider()
        let current = TopologyState(observed)
        settled = current
        phase = .idle
        func match(_ result: String, _ detail: String = "") -> String {
            chainLine(step: "topology-match", result: result,
                      detail: "key=\(current.key) displays=\(current.displayCount)" + detail)
        }
        guard readiness() else {
            log?.write(match("not-ready"))
            return .outcome(.dismissPrompt)
        }
        guard !current.isMirrored else {
            log?.write(match("mirrored"))
            return .outcome(.dismissPrompt)
        }
        guard let topology = presets.topology(key: current.key), !topology.presets.isEmpty else {
            log?.write(match("no-preset"))
            return .outcome(.dismissPrompt)
        }
        guard let auto = topology.autoPreset else {
            log?.write(match("prompt", " presets=\(topology.presets.count)"))
            return .outcome(.promptNeeded(topology))
        }
        log?.write(match("auto", " presets=\(topology.presets.count) preset=\(auto.id)"))
        return .autoRestore(preset: auto, topology: topology, cancellation: claimRestoreLocked(key: current.key))
    }

    private func execute(_ decision: Decision, stableSignature: [String]) {
        switch decision {
        case .outcome(let outcome):
            emit(outcome)
        case .autoRestore(let preset, let topology, let cancellation):
            guard let notice = runRestore(trigger: .auto, snapshot: preset.snapshot, key: topology.key,
                                          presetID: preset.id, cancellation: cancellation,
                                          reapply: false, stableSignature: stableSignature),
                  case .completed(let completion) = notice else { return }  // nil = 本轮中止，重判会给新结果
            emit(.autoRestored(AutoRestoredOutcome(
                topologyKey: topology.key, presetID: preset.id, presetName: preset.name,
                notice: completion, hasOtherPresets: topology.presets.count > 1)))
        }
    }

    // MARK: - 一次性恢复（spec §6.3 单轮 best-effort）

    /// 占住恢复相位并发放取消令牌（调用方持 stateLock 且已确认不在恢复中）
    private func claimRestoreLocked(key: String) -> RestoreCancellation {
        phase = .restoring
        stabilizationPending = false
        pendingReapply = nil
        let cancellation = RestoreCancellation()
        activeRestore = (cancellation, key)
        return cancellation
    }

    /// 调恢复引擎单轮管线（调用方已 claimRestoreLocked）；结束产出完成通知（计数 + [degrade] 附注）。
    /// 返回 nil = 本轮被中止（恢复中拓扑变化）：不记录最近恢复、不产出通知，重判给新结果。
    /// reapply = 余震重放：保留回滚快照、不记录最近恢复（调用方不告知）
    private func runRestore(trigger: RestoreTriggerKind, snapshot: Snapshot, key: String, presetID: String,
                            cancellation: RestoreCancellation, reapply: Bool,
                            stableSignature: [String]?) -> RestoreNotice? {
        log?.write(chainLine(step: "restore-start",
                             detail: "trigger=\(trigger.rawValue) key=\(key) preset=\(presetID)"
                                 + (reapply ? " reapply" : "")))
        // 引擎调用在锁外：恢复可持续数秒，期间事件入口可判拓扑变化并取消
        var report: RestoreReport?
        var failure: Error?
        do {
            report = try restorer.restore(snapshot: snapshot, preserveUndo: reapply, cancellation: cancellation)
        } catch { failure = error }
        let cancelled = report?.cancelled == true

        stateLock.lock()
        if trigger == .auto, report != nil, !cancelled {
            // 余震窗起点 = 最近一次（含重放）完成时刻；重放计数沿用，上限兜底不成循环
            let reapplies = reapply ? (lastAutoRestore?.reapplies ?? TriggerChainConstants.aftershockMaxReapplies) : 0
            lastAutoRestore = AutoRestoreRecord(presetID: presetID, key: key, snapshot: snapshot,
                                                doneAt: clock.now(), reapplies: reapplies,
                                                stableSignature: stableSignature)
        } else {
            lastAutoRestore = nil
        }
        var degradedNames: [String] = []
        if let collector = degradeCollector {
            degradedNames = collector.drainDegradeLayers().map { RestoreNoticeLayers.name(forDegradeLayer: $0) }
        }
        phase = .idle
        activeRestore = nil
        let recheck = eventDuringRestore
        eventDuringRestore = false
        stateLock.unlock()

        defer {
            // 恢复期间来过屏幕事件：按一次新事件重走防抖 → 判定（基线仍是本轮恢复的拓扑）
            if recheck { screenParametersChanged() }
        }
        if let report, cancelled {
            log?.write(chainLine(step: "restore-cancelled",
                                 detail: "trigger=\(trigger.rawValue) key=\(key) ok=\(report.okCount) "
                                     + "skip=\(report.skipCount) fail=\(report.failCount)"))
            return nil
        }
        if let report {
            if !reapply {
                do {
                    try presets.recordRestored(presetID: presetID, topologyKey: key)
                } catch {
                    log?.write(chainLine(step: "record-restored", result: "fail", detail: "error=\(error)"))
                }
            }
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

    // MARK: - 手动恢复（恢复提示「恢复」/ 恢复预设子菜单 / 管理窗口；与自动恢复同一管线）

    /// 恢复当前拓扑下的指定预设（spec §5.2：仅当前拓扑）。topologyKey 与当前拓扑不符、
    /// 镜像中、预设不存在、恢复进行中 → 不恢复返回 nil。成功后记录最近恢复；完成通知经 onNotice 投递。
    @discardableResult
    public func restorePreset(id: String, topologyKey: String) -> RestoreNotice? {
        guard let claim = claimManual(topologyKey: topologyKey, select: { $0.presets.first { $0.id == id } }) else {
            return nil
        }
        return runManual(claim)
    }

    /// restorePreset 的异步形态：选择与占位在调用线程，管线经 restoreEnqueue 离开调用线程（主线程不阻塞）
    public func restorePresetAsync(id: String, topologyKey: String) {
        guard let claim = claimManual(topologyKey: topologyKey, select: { $0.presets.first { $0.id == id } }) else {
            return
        }
        restoreEnqueue { [weak self] in _ = self?.runManual(claim) }
    }

    /// 过渡入口（菜单「立即恢复」，票 06 删除）：恢复当前拓扑的默认预设——自动 → 最近恢复 → 最近保存
    @discardableResult
    public func restoreNow() -> RestoreNotice? {
        guard let claim = claimManual(topologyKey: nil, select: Self.defaultPreset) else { return nil }
        return runManual(claim)
    }

    /// restoreNow 的异步形态（菜单路径）
    public func restoreNowAsync() {
        guard let claim = claimManual(topologyKey: nil, select: Self.defaultPreset) else { return }
        restoreEnqueue { [weak self] in _ = self?.runManual(claim) }
    }

    private static func defaultPreset(in topology: PresetTopology) -> Preset? {
        topology.autoPreset
            ?? topology.presets.first { $0.id == topology.lastRestoredPresetID }
            ?? topology.presets.last
    }

    private struct ManualClaim {
        let preset: Preset
        let key: String
        let cancellation: RestoreCancellation
    }

    /// 手动形态共用：校验当前拓扑 + 选预设 + 忙守卫（含 [trigger] 日志行）；成功即占住恢复相位
    private func claimManual(topologyKey expected: String?,
                             select: (PresetTopology) -> Preset?) -> ManualClaim? {
        let current = TopologyState(topologyProvider())
        stateLock.lock()
        defer { stateLock.unlock() }
        guard phase != .restoring else {
            log?.write(chainLine(step: "ignored", detail: "restore-in-progress trigger=manual"))
            return nil
        }
        func reject(_ result: String) -> ManualClaim? {
            log?.write(chainLine(step: "topology-match", result: result, detail: "key=\(current.key) trigger=manual"))
            return nil
        }
        if let expected, expected != current.key { return reject("topology-mismatch") }
        guard !current.isMirrored else { return reject("mirrored") }
        guard let topology = presets.topology(key: current.key), let preset = select(topology) else {
            return reject("no-preset")
        }
        log?.write(chainLine(step: "topology-match", result: "manual",
                             detail: "key=\(current.key) preset=\(preset.id) trigger=manual"))
        // 防抖/稳定判据进行中被手动恢复抢占：恢复结束后重判（挂起的 settle/采样回调会因相位不符而作废）
        if phase == .debouncing || phase == .stabilizing { eventDuringRestore = true }
        return ManualClaim(preset: preset, key: current.key, cancellation: claimRestoreLocked(key: current.key))
    }

    private func runManual(_ claim: ManualClaim) -> RestoreNotice? {
        guard let notice = runRestore(trigger: .manual, snapshot: claim.preset.snapshot, key: claim.key,
                                      presetID: claim.preset.id, cancellation: claim.cancellation,
                                      reapply: false, stableSignature: nil) else { return nil }
        deliver(notice)
        return notice
    }

    // MARK: - 结果投递与日志

    /// 手动恢复完成通知（系统通知投递）；每条通知都落 notify 日志行
    private func deliver(_ notice: RestoreNotice) {
        log?.write(chainLine(step: "notify", kind: notice.kind, detail: notice.title))
        onNotice(notice)
    }

    /// 判定结果投递（票 05 UI 接缝）；每条都落 outcome 日志行，链路到此收束
    private func emit(_ outcome: TriggerOutcome) {
        log?.write(chainLine(step: "outcome", result: outcome.kind))
        onOutcome(outcome)
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
