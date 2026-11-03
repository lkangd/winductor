import AppKit
import Core
import Foundation
import RestoreEngine
import SnapshotEngine
import SpaceAdapter

// RuntimeAssembly.swift — 装配件（票 18：带就绪门的快照引擎；票 19：全量恢复栈组装）。
// app 入口 target 只依赖 MenubarKit（Package.swift 禁改，不能直 import SnapshotEngine/RestoreEngine/
// SpaceAdapter），故生产组装全部在此：
//   SpaceAdapter（探针/Space 归属）→ 快照引擎（spaces 注入，spaceIndex 现势数据）+ 恢复引擎 + 触发链
//   → MenuRestoreCoordinator（菜单七项接线）→ NotReadyGateCoordinator（票 18 未就绪门控，
//   就绪态菜单 = 全量菜单，未就绪 = 占位骨架 + §8.4 引导块）。
// [degrade] 收集 sink 单实例贯穿（恢复完成通知附注 §8.5 与能力状态行同源）。

public enum RuntimeAssembly {
    /// 组装就绪门接线的快照引擎。storeDirectory/spaces/log 可注入（单测用临时目录；生产默认用户目录）。
    /// spaces = SpaceAdapter（票 19 注入；nil = 降级 spaceIndex，票 12 兼容口径）。
    /// notificationCenters = 引擎内置加速器的观察中心（默认 = 生产口径；全量装配时传 [.default]
    /// 只留屏幕事件，应用启退/Space 切换改由 WorkspaceEventAccelerator 接 NSWorkspace 中心，避免双观察）。
    public static func makeSnapshotEngine(gatedBy monitor: PermissionMonitor,
                                          storeDirectory: URL = SnapshotStore.defaultDirectory,
                                          spaces: SpaceProviding? = nil,
                                          log: LogWriting? = nil,
                                          notificationCenters: [NotificationCenter] = [NSWorkspace.shared.notificationCenter, .default],
                                          visibilityTransitionHandler: (@Sendable ([UInt32]) -> Void)? = nil) -> SnapshotEngine {
        let engine = SnapshotEngine(
            store: SnapshotStore(directory: storeDirectory, log: log),
            spaces: spaces,
            log: log,
            notificationCenters: notificationCenters,
            visibilityTransitionHandler: visibilityTransitionHandler
        )
        engine.readinessGate = { [monitor] in monitor.status.isReady }
        return engine
    }

    /// 全量应用装配（票 19）：返回（未就绪门控协调器, 菜单接线协调器）。
    /// 调用方：gate.start()（首检决策 + 引擎启停 + 菜单）→ menuCoordinator.start()（屏幕观察者）。
    /// - Parameters:
    ///   - statusItem: 状态项呈现（警示点归 StatusPresenting，常态/恢复中图标归 StatusIconControlling）
    ///   - notifier: 系统通知投递（生产 UserNotificationPoster；UNUserNotificationCenter 不可单测）
    ///   - appLog: app 结构化日志 sink（缺省 = FileLogSink 落日志目录 app.log，「打开日志文件夹」所指；
    ///     单测注入内存 sink）
    public static func assembleAppRoot(
        monitor: PermissionMonitor,
        statusItem: StatusPresenting & StatusIconControlling,
        notifier: SystemNotifying,
        loginItem: LoginItemServicing = SMAppServiceLoginItem(),
        storeDirectory: URL = SnapshotStore.defaultDirectory,
        appLog: LogWriting? = nil
    ) -> (gateCoordinator: NotReadyGateCoordinator, menuCoordinator: MenuRestoreCoordinator) {
        let sink = appLog ?? FileLogSink(directory: SnapshotStore.defaultLogDirectory, fileName: "app.log")
        let collector = DegradeCollectingLog(inner: sink)
        let adapter = SpaceAdapter(log: collector)
        let store = SnapshotStore(directory: storeDirectory, log: collector)
        // spec §7.5 加速器分工：引擎只接屏幕事件（.default）；应用启退 + Space 切换由装配件
        // WorkspaceEventAccelerator 接 NSWorkspace 中心（引擎无 Space 切换内置观察，见引擎文件头），
        // 随门控协调器同启同停。
        // 后台窗延迟几何：restore 时 AX 不可见（非可见 Space）的窗记 pending；
        // poller 检测到变可见时由 applier 补写一次（每窗单次，一次性语义保留形态）
        let deferredApplier = DeferredGeometryApplier(store: DeferredGeometryStore(directory: storeDirectory),
                                                      displaysProvider: { Displays.active() },
                                                      log: collector)
        let snapshotEngine = makeSnapshotEngine(gatedBy: monitor,
                                                storeDirectory: storeDirectory,
                                                spaces: adapter,
                                                log: collector,
                                                notificationCenters: [.default],
                                                visibilityTransitionHandler: { [deferredApplier] wids in
                                                    for wid in wids { deferredApplier.applyIfPending(windowID: wid) }
                                                })
        let workspaceAccelerator = WorkspaceEventAccelerator(engine: snapshotEngine)
        let restoreEngine = RestoreEngine(store: store,
                                          spaces: SpaceAdapterBridge(adapter),
                                          log: collector)
        // 后台窗延迟几何的消费轮询：CG isOnscreen 对跨 Space 窗恒 true，迁移事件永不触发；
        // 改为 2s 轮询「pending ∩ 活跃 Space」消费（恢复期间随 poller 一起挂起）
        let pendingConsumer = PendingGeometryConsumer(
            store: DeferredGeometryStore(directory: storeDirectory),
            applier: deferredApplier, adapter: adapter, snapshotEngine: snapshotEngine)
        pendingConsumer.start()
        // 恢复/撤销期间暂停 SnapshotEngine 轮询（poller 的高频 SLS 采样与管线 SLS 读并发冲突，
        // 实测导致 managedSpaces 失败 → entries 空 → 整轮 L2 静默 skip，11-03 生产复现 + DebugCLI 无
        // poller 复测即愈）；完成后自动恢复轮询
        let pollPausing = PollPausingRestorer(base: restoreEngine, snapshotEngine: snapshotEngine)
        let capabilityProbe = SpaceAdapterCapabilityProbe(adapter: adapter)

        // 菜单刷新箱：coordinator 先行构造（refreshMenu 回调指向箱），门控协调器后构造后回填
        let refreshBox = MenuRefreshBox()
        let menuCoordinator = MenuRestoreCoordinator(
            store: store,
            restorer: pollPausing,
            spaces: ManagedSpaceListProvider(adapter),
            scheduler: DispatchTriggerScheduler(),
            log: collector,
            degradeCollector: collector,
            undo: pollPausing,
            icon: statusItem,
            notifier: notifier,
            loginItem: loginItem,
            capabilityLayers: { capabilityProbe.probe() },
            snapshotsFolder: storeDirectory,
            logsFolder: SnapshotStore.defaultLogDirectory,
            refreshMenu: { refreshBox.refresh() })
        let gateCoordinator = NotReadyGateCoordinator(
            monitor: monitor,
            statusItem: statusItem,
            snapshotEngine: snapshotEngine,
            eventAccelerator: workspaceAccelerator,
            makeReadyMenu: { menuCoordinator.makeReadyMenu() })
        refreshBox.targetProvider = gateCoordinator
        return (gateCoordinator, menuCoordinator)
    }
}

/// 菜单刷新目标接缝（NotReadyGateCoordinator.refreshMenuNow 的窄接口）
protocol MenuRefreshTarget: AnyObject {
    func refreshMenuNow()
}

extension NotReadyGateCoordinator: MenuRefreshTarget {}

/// Workspace 事件加速器（spec §7.5「应用启退、Space 切换作为加速器立即触发一次差分」）。
/// 引擎内置加速器只覆盖应用启退与屏幕事件；Space 切换（activeSpaceDidChange）无内置观察，
/// 由装配件在此统一接 engine.pollNow()（公开入口即差分入口）。中心可注入（单测 fake 驱动；
/// 生产默认 NSWorkspace.shared.notificationCenter）。
public final class WorkspaceEventAccelerator {
    private let engine: SnapshotEngine
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    public init(engine: SnapshotEngine,
                center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.engine = engine
        self.center = center
    }

    /// 挂观察（queue: nil = 投递线程同步回调；pollNow 有锁保护，与引擎内置加速器同口径）
    public func start() {
        guard tokens.isEmpty else { return }
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,  // Space 切换（票面缺陷补接）
        ]
        tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.engine.pollNow()  // 加速器：立即差分一次
            }
        }
    }

    /// 摘观察（与门控协调器 stop 同步；应用退出前调用）
    public func stop() {
        for token in tokens { center.removeObserver(token) }
        tokens = []
    }
}

/// 组装期的刷新回填箱（coordinator 先于门控协调器构造，闭包先指箱、后回填目标）
private final class MenuRefreshBox {
    private let lock = NSLock()
    private var target: MenuRefreshTarget?  // 经 targetProvider 存取

    var targetProvider: MenuRefreshTarget? {
        get { lock.lock(); defer { lock.unlock() }; return target }
        set { lock.lock(); self.target = newValue; lock.unlock() }
    }

    func refresh() {
        targetProvider?.refreshMenuNow()
    }
}
