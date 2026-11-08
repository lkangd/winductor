import AppKit
import Core
import RestoreEngine
import SnapshotEngine

// MenuRestoreCoordinator.swift — 菜单接线协调器（票 19，spec §8.1/§8.2/§8.5/§8.6）。
// 职责：组装 TriggerChain（票 17 状态机）并把菜单七项接到引擎/服务——
//   立即恢复 → chain.restoreNow()（best-effort，A6 命令级一致）；恢复经图标装饰器切「恢复中」同步图形
//   （§8.1 三态，结束即回）；完成通知（计数 + [degrade] 附注 §8.5）经 SystemNotifying 接缝投递；
//   撤销上次恢复 → UndoPerforming（canUndo 禁用态 §7.4；两段式第一段投 §8.6 逐字通知）；
//   登录时启动 → LoginItemServicing（SMAppService.mainApp，唯一设置项 §8.2）；
//   Finder 入口 → 目录打开接缝（目录不存在先创建，09 四）；
//   didChangeScreenParameters 观察者 → chain.screenParametersChanged() + 菜单刷新（状态行三态 §8.2）。
// 全部系统单例经协议注入（UNUserNotificationCenter/SMAppService 不可单测；可测接缝全走 fake）。

/// 系统通知投递接缝（生产：UserNotificationPoster 包 UNUserNotificationCenter；测试：fake 收集）
public protocol SystemNotifying: AnyObject {
    func deliver(title: String, body: String)
}

/// 登录项服务接缝（生产：SMAppServiceLoginItem 包 SMAppService.mainApp；测试：fake 记录调用）
public protocol LoginItemServicing: AnyObject {
    var isEnabled: Bool { get }
    func enable() throws
    func disable() throws
}

/// 状态项图标接缝（§8.1 三态中的常态/恢复中两态；未就绪警示点归票 18 StatusPresenting）
public protocol StatusIconControlling: AnyObject {
    /// 常态网格图形
    func showNormalIcon()
    /// 恢复中临时同步图形（恢复结束由装饰器换回常态）
    func showRestoringIcon()
}

/// 撤销入口接缝（生产：RestoreEngine 本体，undo()/canUndo() 即票 16 公开 API；测试：fake）
public protocol UndoPerforming: AnyObject {
    func canUndo() -> Bool
    func undo() throws -> UndoReport
}

extension RestoreEngine: UndoPerforming {}

/// 恢复中图标装饰器（§8.1「恢复中：临时换同步图形，结束即回」）：
/// 包住真实恢复器，恢复开始切同步图形、结束（无论成败）即回常态。分层降级不改图标（§8.1）。
final class RestoringIconDecorator: SnapshotRestoring, @unchecked Sendable {
    private let inner: SnapshotRestoring
    private let icon: StatusIconControlling

    init(inner: SnapshotRestoring, icon: StatusIconControlling) {
        self.inner = inner
        self.icon = icon
    }

    func restore(snapshot: Snapshot) throws -> RestoreReport {
        Self.runOnMain { [icon] in icon.showRestoringIcon() }
        defer { Self.runOnMain { [icon] in icon.showNormalIcon() } }
        return try inner.restore(snapshot: snapshot)
    }

    func restore(snapshot: Snapshot, preserveUndo: Bool) throws -> RestoreReport {
        Self.runOnMain { [icon] in icon.showRestoringIcon() }
        defer { Self.runOnMain { [icon] in icon.showNormalIcon() } }
        return try inner.restore(snapshot: snapshot, preserveUndo: preserveUndo)
    }

    /// 图标属 UI 状态：恢复管线现跑在后台队列（自动路径调度队列 / 手动路径 restoreEnqueue），
    /// NSStatusItem 换图必须主线程（防跨线程 UI 变异）
    private static func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

/// 通知汇集盒（init 两段初始化用：onNotice 闭包先接盒，全部存储属性就绪后再挂 self 处理器）
private final class NoticeSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((RestoreNotice) -> Void)?

    func set(_ newHandler: @escaping (RestoreNotice) -> Void) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }

    func call(_ notice: RestoreNotice) {
        lock.lock()
        let current = handler
        lock.unlock()
        current?(notice)
    }
}

public final class MenuRestoreCoordinator {
    /// 触发链（构造时装配，onNotice 桥接到 handle(notice:) 投递通知）
    private let chain: TriggerChain
    private let undo: UndoPerforming
    private let notifier: SystemNotifying
    private let loginItem: LoginItemServicing
    /// 能力状态行数据源（生产：SpaceAdapterCapabilityProbe；测试：fake 层数组）
    private let capabilityLayers: () -> [CapabilityLayerStatus]
    private let snapshotsFolder: URL
    private let logsFolder: URL
    private let openFolder: (URL) -> Void
    private let refreshMenu: () -> Void
    private let restoreEnqueue: (@escaping @Sendable () -> Void) -> Void
    private let store: TransitionalLiveSnapshots
    private let displaysProvider: () -> [Displays.Info]
    private let log: LogWriting?
    private var screenParamsObserver: NSObjectProtocol?
    /// 菜单打开时原位刷新的委托载体（NSMenuDelegate 必须是 NSObject；
    /// coordinator 引用 init 尾部回填——初始化期不可在存储属性就绪前传 self）
    private final class MenuWillOpenCarrier: NSObject, NSMenuDelegate {
        weak var coordinator: MenuRestoreCoordinator?
        func menuWillOpen(_ menu: NSMenu) { coordinator?.refreshItemsInPlace(menu) }
    }
    private let menuWillOpenCarrier: MenuWillOpenCarrier = MenuWillOpenCarrier()

    public init(store: TransitionalLiveSnapshots,
                restorer: SnapshotRestoring,
                spaces: SpaceListProviding?,
                displaysProvider: @escaping () -> [Displays.Info] = Displays.active,
                scheduler: TriggerChainScheduling = DispatchTriggerScheduler(),
                restoreEnqueue: @escaping (@escaping @Sendable () -> Void) -> Void = { work in
                    DispatchQueue(label: "winductor.restore", qos: .userInitiated).async(execute: work)
                },
                log: LogWriting? = nil,
                degradeCollector: DegradeCollectingLog? = nil,
                undo: UndoPerforming,
                icon: StatusIconControlling,
                notifier: SystemNotifying,
                loginItem: LoginItemServicing,
                capabilityLayers: @escaping () -> [CapabilityLayerStatus],
                snapshotsFolder: URL,
                logsFolder: URL,
                openFolder: @escaping (URL) -> Void = { FinderFolderOpener.open($0) },
                refreshMenu: @escaping () -> Void) {
        self.store = store
        self.restoreEnqueue = restoreEnqueue
        self.undo = undo
        self.notifier = notifier
        self.loginItem = loginItem
        self.capabilityLayers = capabilityLayers
        self.snapshotsFolder = snapshotsFolder
        self.logsFolder = logsFolder
        self.openFolder = openFolder
        self.refreshMenu = refreshMenu
        self.displaysProvider = displaysProvider
        self.log = log
        // 图标三态装饰（恢复开始/结束换图；§8.1），降级不换图
        let decorated = RestoringIconDecorator(inner: restorer, icon: icon)
        let noticeSink = NoticeSink()
        chain = TriggerChain(store: store,
                             restorer: decorated,
                             spaces: spaces,
                             displaysProvider: displaysProvider,
                             scheduler: scheduler,
                             log: log,
                             degradeCollector: degradeCollector,
                             restoreEnqueue: restoreEnqueue,
                             onNotice: { noticeSink.call($0) })
        // 引用 self 的成员放在全部存储属性初始化之后
        menuWillOpenCarrier.coordinator = self
        noticeSink.set { [weak self] notice in self?.handle(notice: notice) }
    }

    deinit {
        if let observer = screenParamsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: 生命周期

    /// 启动：观察屏幕参数变化（spec §6.2 触发链唯一入口；睡眠唤醒/分辨率微调同入口零动作口径在链内）
    public func start() {
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.screenParametersDidChange()
            }
    }

    /// 停止观察者与触发链挂起回调（应用退出前由装配方调用）
    public func stop() {
        if let observer = screenParamsObserver {
            NotificationCenter.default.removeObserver(observer)
            screenParamsObserver = nil
        }
        chain.stop()
    }

    // MARK: 屏幕参数变化（观察者入口；单测直调）

    /// 事件 → 触发链（防抖 1.5s 起；预判为插屏余震时 0.5s）+ 菜单刷新（状态行三态随拓扑切换）
    func screenParametersDidChange() {
        chain.screenParametersChanged()
        refreshMenuOnMain()
    }

    /// 通知桥接（TriggerChain onNotice → 系统通知投递 + 菜单刷新）
    func handle(notice: RestoreNotice) {
        notifier.deliver(title: notice.title, body: notice.body)
        refreshMenuOnMain()
    }

    // MARK: 全量菜单（注入 NotReadyGateCoordinator.makeReadyMenu）

    /// 按 §8.2 构建全量菜单（状态/可用性取构建时刻现状）
    public func makeReadyMenu() -> NSMenu {
        let menu = WiredMenuBuilder.build(currentContent())
        menu.delegate = menuWillOpenCarrier  // 打开时原位重算（拓扑/撤销/勾选态跟随现状）
        return menu
    }

    /// 菜单打开时原位刷新（重建条目到同一 NSMenu 实例，避免打开中途换菜单实例）
    public func refreshItemsInPlace(_ menu: NSMenu) {
        let fresh = WiredMenuBuilder.build(currentContent())
        menu.removeAllItems()
        // NSMenuItem 不能同属两个菜单：先从临时菜单摘下再插入
        while let item = fresh.items.first {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }

    /// 构建时刻的菜单内容（状态行三态 §8.2、canUndo §7.4、登录勾选态、能力状态行 §8.5）
    private func currentContent() -> WiredMenuContent {
        WiredMenuContent(
            statusLineTitle: currentStatusLineTitle(),
            canUndo: undo.canUndo(),
            loginLaunchChecked: loginItem.isEnabled,
            capabilityTitle: CapabilityStatusLine.title(for: capabilityLayers()),
            onRestoreNow: { [weak self] in self?.restoreNowTapped() },
            onUndo: { [weak self] in self?.undoLastTapped() },
            onToggleLoginLaunch: { [weak self] in self?.toggleLoginLaunchTapped() },
            onOpenSnapshotsFolder: { [weak self] in self?.openSnapshotsFolderTapped() },
            onOpenLogsFolder: { [weak self] in self?.openLogsFolderTapped() })
    }

    /// 状态行三态判定（spec §8.2）：当前显示器数 + 现势快照（live-<拓扑键>）集合精确匹配
    private func currentStatusLineTitle() -> String {
        let displays = displaysProvider()
        let uuids = displays.compactMap(\.uuid).filter { !$0.isEmpty }
        let hasMatch: Bool = {
            guard !uuids.isEmpty,
                  let snapshot = store.loadLive(topologyKey: TransitionalLiveSnapshots.topologyKey(forDisplayUUIDs: uuids)) else {
                return false
            }
            return Set(snapshot.topology.map(\.uuid)) == Set(uuids)
        }()
        return StatusLineState.state(displayCount: displays.count, hasMatchingLiveSnapshot: hasMatch).title
    }

    // MARK: 菜单动作（经 WiredMenuBuilder 载体路由；与真实点击同路径）

    private func restoreNowTapped() {
        chain.restoreNowAsync()  // 管线离主线程（修复 2 屏拓扑点立即恢复卡死）；完成通知经 onNotice 桥接投递（§8.5 计数 + 降级附注）
    }

    private func undoLastTapped() {
        // undo 跑全量回滚管线（分钟级），与立即恢复同修复：经执行器离主线程；
        // 通知投递线程安全（UNUserNotificationCenter），菜单刷新自带主线程汇编
        restoreEnqueue { [weak self] in
            self?.performUndoAndNotify()
        }
    }

    private func performUndoAndNotify() {
        do {
            let report = try undo.undo()
            if report.isTwoStageFirstPass {
                // §8.6 第一段：逐字通知（N = fullscreenPendingCount）
                notifier.deliver(title: "撤销完成", body: report.twoStageNotificationText ?? "")
            } else {
                // 单层完成：计数通知（命令级 undo 输出的菜单栏形态，§8.5 同构措辞）
                notifier.deliver(title: "撤销完成",
                                 body: "撤销完成：\(report.okCount) 窗口归位、\(report.skipCount) 跳过、\(report.failCount) 失败")
            }
        } catch RestoreEngineError.undoSnapshotMissing {
            notifier.deliver(title: "撤销失败", body: "撤销失败：无可用回滚快照")
        } catch RestoreEngineError.undoSnapshotCorrupt {
            notifier.deliver(title: "撤销失败", body: "撤销失败：回滚快照不可用（已按 §7.4 隔离，下次恢复重写）")
        } catch RestoreEngineError.noActiveDisplay {
            notifier.deliver(title: "撤销失败", body: "撤销失败：无活动显示器")
        } catch {
            notifier.deliver(title: "撤销失败", body: "撤销失败：\(String(describing: error))")
        }
        refreshMenuOnMain()
    }

    private func toggleLoginLaunchTapped() {
        do {
            if loginItem.isEnabled {
                try loginItem.disable()
            } else {
                try loginItem.enable()
            }
        } catch {
            log?.write("[login-item] toggle failed error=\(String(describing: error))")
        }
        refreshMenuOnMain()
    }

    private func openSnapshotsFolderTapped() {
        openFolder(snapshotsFolder)
    }

    private func openLogsFolderTapped() {
        openFolder(logsFolder)
    }

    /// 菜单刷新主线程归一（触发链回调可能在调度队列线程）
    private func refreshMenuOnMain() {
        let work = { [refreshMenu] in refreshMenu() }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
