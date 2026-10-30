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
    public static func makeSnapshotEngine(gatedBy monitor: PermissionMonitor,
                                          storeDirectory: URL = SnapshotStore.defaultDirectory,
                                          spaces: SpaceProviding? = nil,
                                          log: LogWriting? = nil) -> SnapshotEngine {
        let engine = SnapshotEngine(
            store: SnapshotStore(directory: storeDirectory, log: log),
            spaces: spaces,
            log: log
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
        let snapshotEngine = makeSnapshotEngine(gatedBy: monitor,
                                                storeDirectory: storeDirectory,
                                                spaces: adapter,
                                                log: collector)
        let restoreEngine = RestoreEngine(store: store,
                                          spaces: SpaceAdapterBridge(adapter),
                                          log: collector)
        let capabilityProbe = SpaceAdapterCapabilityProbe(adapter: adapter)

        // 菜单刷新箱：coordinator 先行构造（refreshMenu 回调指向箱），门控协调器后构造后回填
        let refreshBox = MenuRefreshBox()
        let menuCoordinator = MenuRestoreCoordinator(
            store: store,
            restorer: restoreEngine,
            spaces: ManagedSpaceListProvider(adapter),
            scheduler: DispatchTriggerScheduler(),
            log: collector,
            degradeCollector: collector,
            undo: restoreEngine,
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
