import AppKit
import Core
import Foundation
import RestoreEngine
import SnapshotEngine
import SpaceAdapter

// RuntimeAssembly.swift — 装配件（票 18：未就绪门控；票 19：全量恢复栈组装；票 03：保存预设流程见 SavePresetFlow.swift）。
// app 入口 target 只依赖 MenubarKit（Package.swift 禁改，不能直 import SnapshotEngine/RestoreEngine/
// SpaceAdapter），故生产组装全部在此：
//   SpaceAdapter（探针/Space 归属）→ 恢复引擎 + 触发链 + 保存预设流程
//   → MenuRestoreCoordinator（spec §6.1 菜单接线）→ NotReadyGateCoordinator（票 18 未就绪门控，
//   就绪态菜单 = 全量菜单，未就绪 = 占位骨架 + §8.4 引导块）。
// [degrade] 收集 sink 单实例贯穿（恢复完成通知附注 §8.5 与能力状态行同源）。

public enum RuntimeAssembly {
    /// 全量应用装配（票 19）：返回（未就绪门控协调器, 菜单接线协调器）。
    /// 调用方：gate.start()（首检决策 + 菜单）→ menuCoordinator.start()（屏幕观察者）。
    /// - Parameters:
    ///   - statusItem: 状态项呈现（警示点归 StatusPresenting，常态/恢复中图标归 StatusIconControlling）
    ///   - notifier: 系统通知投递（生产 UserNotificationPoster；UNUserNotificationCenter 不可单测）
    ///   - popoverAnchor: 恢复提示 / 自动恢复告知 popover 的锚点（生产 = 状态项按钮；nil = 不弹 popover）
    ///   - appLog: app 结构化日志 sink（缺省 = FileLogSink 落日志目录 app.log，「打开日志文件夹」所指；
    ///     单测注入内存 sink）
    public static func assembleAppRoot(
        monitor: PermissionMonitor,
        statusItem: StatusPresenting & StatusIconControlling,
        notifier: SystemNotifying,
        loginItem: LoginItemServicing = SMAppServiceLoginItem(),
        storeDirectory: URL = PresetStore.defaultDirectory,
        popoverAnchor: (() -> NSView?)? = nil,
        appLog: LogWriting? = nil
    ) -> (gateCoordinator: NotReadyGateCoordinator, menuCoordinator: MenuRestoreCoordinator) {
        let sink = appLog ?? FileLogSink(directory: SnapshotStore.defaultLogDirectory, fileName: "app.log")
        let collector = DegradeCollectingLog(inner: sink)
        let adapter = SpaceAdapter(log: collector)
        // 预设存储（回滚快照 + 触发链按预设判定 + 菜单状态行/恢复预设子菜单 + 保存预设，同一实例）
        let presetStore = PresetStore(directory: storeDirectory, log: collector)
        // 恢复/撤销管线独占 SkyLight：拍快照与 pending 补写在管线运行期间让出
        // （并发 SLS 读实测导致 managedSpaces 失败 → 整轮 L2 静默 skip，11-03 生产复现）
        let session = SkyLightSession(log: collector)
        // 后台窗延迟几何：恢复记录、快照覆盖、可见即补写同在一个模块（自驱轮询随 app 生命周期）
        let bridge = SpaceAdapterBridge(adapter)
        let deferredGeometry = DeferredGeometry(directory: storeDirectory, spaces: bridge,
                                                session: session, log: collector)
        let restoreEngine = RestoreEngine(store: presetStore,
                                          spaces: bridge,
                                          session: session,
                                          deferredGeometry: deferredGeometry,
                                          log: collector)
        deferredGeometry.start()
        let capabilityProbe = SpaceAdapterCapabilityProbe(adapter: adapter)
        // 「保存当前布局为预设…」：一次性拍快照（与恢复管线共用 session 独占、共用延迟几何覆盖）
        let savePreset = makeSavePresetFlow(gatedBy: monitor, store: presetStore, spaces: adapter, session: session,
                                            deferredGeometry: deferredGeometry, notifier: notifier, log: collector)

        // 菜单刷新箱：coordinator 先行构造（refreshMenu 回调指向箱），门控协调器后构造后回填
        let refreshBox = MenuRefreshBox()
        let menuCoordinator = MenuRestoreCoordinator(
            presetStore: presetStore,
            restorer: restoreEngine,
            spaces: ManagedSpaceListProvider(adapter),
            readiness: { [monitor] in monitor.status.isReady },
            scheduler: DispatchTriggerScheduler(),
            log: collector,
            degradeCollector: collector,
            undo: restoreEngine,
            icon: statusItem,
            notifier: notifier,
            loginItem: loginItem,
            capabilityLayers: { capabilityProbe.probe() },
            savePreset: savePreset,
            presetsFolder: storeDirectory,
            logsFolder: SnapshotStore.defaultLogDirectory,
            refreshMenu: { refreshBox.refresh() },
            // 恢复提示的 Space 不足对比：恢复/撤销管线独占 SkyLight 时让出（读不到 = 不提示）
            currentSpaces: { session.shared { session.slsRead { try? adapter.managedSpaces() } } ?? nil },
            popover: popoverAnchor.map { StatusItemPopoverPresenter(anchor: $0) })
        let gateCoordinator = NotReadyGateCoordinator(
            monitor: monitor,
            statusItem: statusItem,
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
