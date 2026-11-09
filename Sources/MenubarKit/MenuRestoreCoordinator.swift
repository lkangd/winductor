import AppKit
import Core
import RestoreEngine
import SnapshotEngine

// MenuRestoreCoordinator.swift — 菜单接线协调器（票 19 起步；display-presets 票 06 改为 display-presets spec §6.1 菜单）。
// 职责：组装 TriggerChain（按预设判定）并把菜单各项接到引擎/服务——
//   状态行 → StatusLineState 四态（当前观测拓扑 + PresetStore 中该拓扑的预设）；
//   保存当前布局为预设… → SavePresetFlow.runAsync（拍快照离主线程，输入框回主线程；保存后刷新菜单）；
//   恢复预设 ▸ → chain.restorePresetAsync（与自动恢复同一管线，成功后链记录最近恢复）；恢复经图标装饰器切
//   「恢复中」同步图形（§8.1 三态，结束即回）；完成通知（计数 + [degrade] 附注 §8.5）经 SystemNotifying 接缝投递；
//   撤销上次恢复 → UndoPerforming（canUndo 禁用态 §7.4；两段式第一段投 §8.6 逐字通知）；
//   管理预设… → 注入的打开入口（统一主窗口并选中当前拓扑，ui-refactor 票 03；未注入置灰）；
//   登录时启动 → LoginItemServicing（SMAppService.mainApp）；Finder 入口 → 目录打开接缝（目录不存在先创建）；
//   didChangeScreenParameters 观察者 → chain.screenParametersChanged() + 菜单刷新；
//   触发链判定结果（display-presets §5.1）→ handle(outcome:) → RestorePopoverCoordinator（恢复提示 / 自动恢复告知
//   popover，§6.2/§6.3；提示「恢复」= restorePreset（菜单同入口，被拒告知），告知「撤销」= 菜单同款撤销管线）。
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

    /// 取消令牌必须转发（触发链恢复中拓扑变化即中止本轮）
    func restore(snapshot: Snapshot, preserveUndo: Bool, cancellation: RestoreCancellation?) throws -> RestoreReport {
        Self.runOnMain { [icon] in icon.showRestoringIcon() }
        defer { Self.runOnMain { [icon] in icon.showNormalIcon() } }
        return try inner.restore(snapshot: snapshot, preserveUndo: preserveUndo, cancellation: cancellation)
    }

    /// 图标属 UI 状态：恢复管线现跑在后台队列（自动路径调度队列 / 手动路径 restoreEnqueue），
    /// NSStatusItem 换图必须主线程（防跨线程 UI 变异）
    private static func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

/// 回调汇集盒（init 两段初始化用：onNotice/onOutcome 闭包先接盒，全部存储属性就绪后再挂 self 处理器）
private final class NoticeSink<Payload>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Payload) -> Void)?

    func set(_ newHandler: @escaping (Payload) -> Void) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }

    func call(_ notice: Payload) {
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
    private let presetsFolder: URL
    private let logsFolder: URL
    private let openFolder: (URL) -> Void
    private let refreshMenu: () -> Void
    private let restoreEnqueue: (@escaping @Sendable () -> Void) -> Void
    private let presetStore: PresetStore
    private let topologyProvider: () -> ObservedTopology
    private let savePreset: SavePresetFlow
    private let openPresetManager: (() -> Void)?
    private let overwritePreset: OverwritePresetFlow?
    private let log: LogWriting?
    private var screenParamsObserver: NSObjectProtocol?
    /// 恢复提示 / 自动恢复告知（init 尾部构造：撤销闭包要引用 self）
    private var popovers: RestorePopoverCoordinator?
    /// 菜单打开时原位刷新的委托载体（NSMenuDelegate 必须是 NSObject；
    /// coordinator 引用 init 尾部回填——初始化期不可在存储属性就绪前传 self）
    private final class MenuWillOpenCarrier: NSObject, NSMenuDelegate {
        weak var coordinator: MenuRestoreCoordinator?
        func menuWillOpen(_ menu: NSMenu) { coordinator?.refreshItemsInPlace(menu) }
    }
    private let menuWillOpenCarrier: MenuWillOpenCarrier = MenuWillOpenCarrier()

    /// - presetStore / topologyProvider：触发链按预设判定（display-presets §5.1）与状态行、恢复预设子菜单同源
    /// - readiness：触发链未就绪门
    /// - savePreset：「保存当前布局为预设…」流程（RuntimeAssembly.makeSavePresetFlow）
    /// - openPresetManager：「管理预设…」打开入口（display-presets 票 07 注入；nil = 置灰）
    /// - overwritePreset：「恢复预设 ▸」内「用当前布局覆盖 ▸」流程（display-presets 票 07，与管理窗口同一实例；nil = 不显示）
    public init(presetStore: PresetStore,
                restorer: SnapshotRestoring,
                spaces: SpaceListProviding?,
                topologyProvider: @escaping () -> ObservedTopology = ObservedTopology.current,
                readiness: @escaping () -> Bool = { true },
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
                savePreset: SavePresetFlow,
                openPresetManager: (() -> Void)? = nil,
                overwritePreset: OverwritePresetFlow? = nil,
                presetsFolder: URL,
                logsFolder: URL,
                openFolder: @escaping (URL) -> Void = { FinderFolderOpener.open($0) },
                refreshMenu: @escaping () -> Void,
                currentSpaces: @escaping () -> [SpaceEntry]? = { nil },
                popover: RestorePopoverRendering? = nil) {
        self.presetStore = presetStore
        self.topologyProvider = topologyProvider
        self.savePreset = savePreset
        self.openPresetManager = openPresetManager
        self.overwritePreset = overwritePreset
        self.restoreEnqueue = restoreEnqueue
        self.undo = undo
        self.notifier = notifier
        self.loginItem = loginItem
        self.capabilityLayers = capabilityLayers
        self.presetsFolder = presetsFolder
        self.logsFolder = logsFolder
        self.openFolder = openFolder
        self.refreshMenu = refreshMenu
        self.log = log
        // 图标三态装饰（恢复开始/结束换图；§8.1），降级不换图
        let decorated = RestoringIconDecorator(inner: restorer, icon: icon)
        let noticeSink = NoticeSink<RestoreNotice>()
        let outcomeSink = NoticeSink<TriggerOutcome>()
        chain = TriggerChain(presets: presetStore,
                             restorer: decorated,
                             spaces: spaces,
                             topologyProvider: topologyProvider,
                             readiness: readiness,
                             scheduler: scheduler,
                             log: log,
                             degradeCollector: degradeCollector,
                             restoreEnqueue: restoreEnqueue,
                             onNotice: { noticeSink.call($0) },
                             onOutcome: { outcomeSink.call($0) })
        // 引用 self 的成员放在全部存储属性初始化之后
        menuWillOpenCarrier.coordinator = self
        noticeSink.set { [weak self] notice in self?.handle(notice: notice) }
        outcomeSink.set { [weak self] outcome in self?.handle(outcome: outcome) }
        popovers = RestorePopoverCoordinator(
            renderer: popover, presets: presetStore, currentSpaces: currentSpaces,
            // 与菜单/管理窗口同一入口：被拒时同口径告知用户
            restorePreset: { [weak self] id, key in self?.restorePreset(id: id, topologyKey: key) },
            undo: { [weak self] in self?.undoLastTapped() },
            log: log)
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

    /// 事件 → 触发链（防抖 1.5s 起；预判为插屏余震时 0.5s）+ 菜单刷新（状态行四态随拓扑切换）
    func screenParametersDidChange() {
        chain.screenParametersChanged()
        refreshMenuOnMain()
    }

    /// 通知桥接（TriggerChain onNotice → 系统通知投递 + 菜单刷新）
    func handle(notice: RestoreNotice) {
        notifier.deliver(title: notice.title, body: notice.body)
        refreshMenuOnMain()
    }

    /// 判定结果桥接（TriggerChain onOutcome，spec §5.1）→ 恢复提示 / 自动恢复告知 popover（§6.2/§6.3）。
    /// 自动恢复不再发系统通知；手动恢复（含提示「恢复」）的完成通知仍经 onNotice 投递。
    func handle(outcome: TriggerOutcome) {
        popovers?.handle(outcome: outcome)
        refreshMenuOnMain()
    }

    // MARK: 全量菜单（注入 NotReadyGateCoordinator.makeReadyMenu）

    /// 按 spec §6.1 构建全量菜单（状态/可用性取构建时刻现状）
    public func makeReadyMenu() -> NSMenu {
        let menu = WiredMenuBuilder.build(menuContent())
        menu.delegate = menuWillOpenCarrier  // 打开时原位重算（拓扑/预设/撤销/勾选态跟随现状）
        return menu
    }

    /// 菜单打开时原位刷新（重建条目到同一 NSMenu 实例，避免打开中途换菜单实例）
    public func refreshItemsInPlace(_ menu: NSMenu) {
        let fresh = WiredMenuBuilder.build(menuContent())
        menu.removeAllItems()
        // NSMenuItem 不能同属两个菜单：先从临时菜单摘下再插入
        while let item = fresh.items.first {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }

    /// 手动恢复当前拓扑下的指定预设（菜单「恢复预设 ▸」、管理窗口「恢复」、恢复提示「恢复」同入口）：
    /// 与自动恢复同一管线，离主线程执行；拓扑已变 / 镜像中 / 预设已删 / 恢复进行中则不恢复，
    /// 经通知告知用户并返回原因（nil = 已受理）
    @discardableResult
    public func restorePreset(id: String, topologyKey: String) -> ManualRestoreRejection? {
        guard let rejection = chain.restorePresetAsync(id: id, topologyKey: topologyKey) else { return nil }
        notifier.deliver(title: "未恢复预设", body: Self.message(for: rejection))
        refreshMenuOnMain()  // 入口按旧状态构建（如拓扑已变）：刷新到现状
        return rejection
    }

    /// 手动恢复被拒的用户文案
    static func message(for rejection: ManualRestoreRejection) -> String {
        switch rejection {
        case .topologyChanged: return "屏幕排列已变化，只能恢复当前屏幕排列下的预设"
        case .mirrored: return "镜像中，不能恢复预设"
        case .presetMissing: return "预设不存在（可能已被删除）"
        case .restoreInProgress: return "恢复进行中，请稍后再试"
        }
    }

    /// 构建时刻的菜单内容（状态行四态、恢复预设子菜单、保存可用性、canUndo、登录勾选态、能力状态行）。
    /// 主窗口通用页（ui-refactor 票 03）取同一份：勾选态 / 撤销可用性 / 动作闭包与菜单同源
    public func menuContent() -> WiredMenuContent {
        let observed = topologyProvider()
        let key = observed.identity.key
        // 镜像中整体禁用（spec §3.3）：不列预设
        let record = observed.isMirrored ? nil : presetStore.topology(key: key)
        let presets = record?.presets ?? []
        return WiredMenuContent(
            statusLineTitle: StatusLineState.title(displayCount: observed.displays.count,
                                                   isMirrored: observed.isMirrored,
                                                   presetCount: presets.count,
                                                   autoPresetName: record?.autoPreset?.name),
            canSavePreset: savePreset.availability() == .available,
            restorePresets: presets.map { RestorePresetMenuEntry(id: $0.id, name: $0.name, isAuto: $0.isAuto) },
            canUndo: undo.canUndo(),
            loginLaunchChecked: loginItem.isEnabled,
            capabilityTitle: CapabilityStatusLine.title(for: capabilityLayers()),
            onSavePreset: { [weak self] in self?.savePresetTapped() },
            // 绑定构建时刻的拓扑键：点击前拓扑已变 → 链按 topology-mismatch 拒绝
            onRestorePreset: { [weak self] id in self?.restorePreset(id: id, topologyKey: key) },
            onUndo: { [weak self] in self?.undoLastTapped() },
            onManagePresets: openPresetManager,
            onToggleLoginLaunch: { [weak self] in self?.toggleLoginLaunchTapped() },
            onOpenPresetsFolder: { [weak self] in self?.openPresetsFolderTapped() },
            onOpenLogsFolder: { [weak self] in self?.openLogsFolderTapped() },
            canOverwritePreset: overwritePreset?.availability() == .available,
            // 同恢复：绑定构建时刻的拓扑键，覆盖流程拍快照后再核对拓扑
            onOverwritePreset: overwritePreset.map { flow in
                { [weak self] id in flow.runAsync(presetID: id, topologyKey: key) { _ in self?.refreshMenuOnMain() } }
            })
    }

    // MARK: 菜单动作（经 WiredMenuBuilder 载体路由；与真实点击同路径）

    private func savePresetTapped() {
        // 拍快照离主线程、输入框回主线程；存入后刷新（状态行与「恢复预设 ▸」随之更新）
        savePreset.runAsync { [weak self] outcome in
            if case .saved = outcome { self?.refreshMenuOnMain() }
        }
    }

    private func undoLastTapped() {
        // undo 跑全量回滚管线（分钟级）：经执行器离主线程；
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

    private func openPresetsFolderTapped() {
        openFolder(presetsFolder)
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
