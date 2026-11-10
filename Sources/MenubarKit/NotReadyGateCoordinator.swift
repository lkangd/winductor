import AppKit

// NotReadyGateCoordinator.swift — 未就绪链路协调器（票 18，spec §4.6/§8.3/§8.4）。
// 职责：把 PermissionMonitor 的状态变化接到三处呈现——
//   1. 状态项未就绪徽记（ui-refactor spec §4.2：常态图 + 镂空「!」，画进模板图）
//   2. 菜单：运行中屏幕录制重确认降级 → 顶部 §8.4 逐字引导块（不弹窗）；恢复 → 占位骨架回归
//   3. 引导窗：仅首启未就绪弹一次（§8.3），就绪后窗内换重启提示；运行中降级绝不弹窗（§8.4）；
//      通用页「授权引导…」按需打开——本次运行中从未未就绪则齐备态无需重启（授权在启动前已生效）
// 呈现经接缝注入（StatusPresenting/GuideWindowPresenting），单测用假件驱动。

/// 状态项呈现接缝（生产：StatusItemController；测试：假件——无 Aqua 会话时 NSStatusBar 崩溃）
public protocol StatusPresenting: AnyObject {
    func setShowsNotReadyBadge(_ visible: Bool)
    func set(menu: NSMenu)
}

extension StatusItemController: StatusPresenting {}

/// 引导窗呈现接缝（生产：PermissionGuideWindow；测试：假件）
public protocol GuideWindowPresenting: AnyObject {
    func show()
    /// - Parameter hasBeenNotReady: 本次运行中是否出现过未就绪（决定齐备态是否提示重启）
    func update(status: PermissionMonitor.Status, hasBeenNotReady: Bool)
}

extension PermissionGuideWindow: GuideWindowPresenting {}

public final class NotReadyGateCoordinator {
    /// 观察者（公开供装配方复用同一实例接引擎就绪门等）
    public let monitor: PermissionMonitor

    private let statusItem: StatusPresenting
    private let makeGuideWindow: () -> GuideWindowPresenting
    private var guideWindow: GuideWindowPresenting?
    /// 首启弹窗决策只做一次：此后任何状态变化不再创建引导窗（§8.4 运行中降级不弹窗）
    private var hasDecidedInitialGuide = false
    /// 本次运行中是否出现过未就绪（首启未就绪或运行中重确认降级）：授权须重启应用一次才生效（docs/signing.md §5），
    /// 出现过则齐备后要重启；启动即就绪且从未降级 = 授权早已生效，无需重启。只置不清（重启 = 新进程）
    private var hasBeenNotReady = false
    /// 菜单动作载体：状态行点击直达系统设置的录屏与系统录音面板（强持有防释放）
    private let menuActionCarrier: ActionCarrier
    /// 就绪态菜单构建闭包（票 19 全量菜单注入；缺省 = 票 18 占位骨架，未就绪恒占位骨架）
    private let makeReadyMenu: () -> NSMenu

    public init(monitor: PermissionMonitor,
                statusItem: StatusPresenting,
                makeGuideWindow: @escaping () -> GuideWindowPresenting = { PermissionGuideWindow() },
                openScreenCaptureSettings: @escaping () -> Void = { SystemSettingsOpener.open(.screenCapture) },
                makeReadyMenu: @escaping () -> NSMenu = { PlaceholderMenu.build() }) {
        self.monitor = monitor
        self.statusItem = statusItem
        self.makeGuideWindow = makeGuideWindow
        self.makeReadyMenu = makeReadyMenu
        self.menuActionCarrier = ActionCarrier(openScreenCaptureSettings)
    }

    /// 启动：接线观察者回调 + 每 2s 定时检测 + 按首检现状做弹窗决策（§8.3）。
    /// 无后台快照引擎可启（display-presets 票 03：快照只在保存预设时一次性拍）。
    public func start() {
        monitor.onStatusChange = { [weak self] status in self?.apply(status) }
        monitor.start()  // 立即首检，就绪门随即反映真实现状
        apply(monitor.status)
    }

    /// 停止观察者（应用退出前由装配方调用）
    public func stop() {
        monitor.stop()
    }

    /// 强制重建菜单（票 19：恢复/撤销/屏幕拓扑变化等权限外事件后的刷新入口；
    /// 就绪态走注入的 makeReadyMenu 全量菜单，未就绪保持占位骨架）
    public func refreshMenuNow() {
        refreshMenu(monitor.status)
    }

    /// 按需打开授权引导窗（主窗口通用页「授权引导…」，ui-refactor 票 03）：已有窗口则前置，否则新建；随后照常跟随状态推进
    public func showPermissionGuide() {
        presentGuide(monitor.status)
    }

    // MARK: 状态应用（主线程；观察者定时路径已投递主线程）

    private func apply(_ status: PermissionMonitor.Status) {
        if !status.isReady { hasBeenNotReady = true }
        statusItem.setShowsNotReadyBadge(!status.isReady)
        refreshMenu(status)

        if !hasDecidedInitialGuide {
            hasDecidedInitialGuide = true
            guard !status.isReady else { return }  // 启动时就绪：不弹（重启后授权生效不再弹）
            presentGuide(status)
        } else {
            guideWindow?.update(status: status, hasBeenNotReady: hasBeenNotReady)  // 已有授权窗跟随推进（逐项状态；等待 ⇄ 齐备重启提示，ui-refactor §6）
        }
    }

    /// 呈现授权窗：已有则复用（单实例），推进到给定现状后前置
    private func presentGuide(_ status: PermissionMonitor.Status) {
        let window = guideWindow ?? makeGuideWindow()
        window.update(status: status, hasBeenNotReady: hasBeenNotReady)
        window.show()
        guideWindow = window
    }

    /// 重建菜单：就绪 → 注入的全量菜单（票 19）；未就绪 → 占位骨架，重确认态顶部换 §8.4 引导块
    private func refreshMenu(_ status: PermissionMonitor.Status) {
        let menu = status.isReady ? makeReadyMenu() : PlaceholderMenu.build()
        if status.screenCaptureNeedsReconfirm {
            ScreenCaptureReconfirmGuide.install(
                into: menu,
                statusLineTarget: menuActionCarrier,
                action: #selector(ActionCarrier.fire)
            )
        }
        statusItem.set(menu: menu)
    }
}
