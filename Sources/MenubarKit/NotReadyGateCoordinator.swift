import AppKit

// NotReadyGateCoordinator.swift — 未就绪链路协调器（票 18，spec §4.6/§8.3/§8.4）。
// 职责：把 PermissionMonitor 的状态变化接到三处呈现——
//   1. 状态项警示点（§8.1 未就绪态：网格图 + 黄色警示点）
//   2. 菜单：运行中屏幕录制重确认降级 → 顶部 §8.4 逐字引导块（不弹窗）；恢复 → 占位骨架回归
//   3. 引导窗：仅首启未就绪弹一次（§8.3），就绪后窗内换重启提示；运行中降级绝不弹窗（§8.4）
// 呈现经接缝注入（StatusPresenting/GuideWindowPresenting），单测用假件驱动。

/// 状态项呈现接缝（生产：StatusItemController；测试：假件——无 Aqua 会话时 NSStatusBar 崩溃）
public protocol StatusPresenting: AnyObject {
    func setShowsWarningDot(_ visible: Bool)
    func set(menu: NSMenu)
}

extension StatusItemController: StatusPresenting {}

/// 引导窗呈现接缝（生产：PermissionGuideWindow；测试：假件）
public protocol GuideWindowPresenting: AnyObject {
    func show()
    func update(status: PermissionMonitor.Status)
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
    /// 菜单动作载体：状态行点击直达系统设置的屏幕与系统录音面板（强持有防释放）
    private let menuActionCarrier: MenuActionCarrier
    /// 就绪态菜单构建闭包（票 19 全量菜单注入；缺省 = 票 18 占位骨架，未就绪恒占位骨架）
    private let makeReadyMenu: () -> NSMenu

    /// 菜单动作载体（§8.4 状态行 target/action 需要 NSObject 目标）
    private final class MenuActionCarrier: NSObject {
        private let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func openScreenCaptureSettings() { handler() }
    }

    public init(monitor: PermissionMonitor,
                statusItem: StatusPresenting,
                makeGuideWindow: @escaping () -> GuideWindowPresenting = { PermissionGuideWindow() },
                openScreenCaptureSettings: @escaping () -> Void = { SystemSettingsOpener.open(.screenCapture) },
                makeReadyMenu: @escaping () -> NSMenu = { PlaceholderMenu.build() }) {
        self.monitor = monitor
        self.statusItem = statusItem
        self.makeGuideWindow = makeGuideWindow
        self.makeReadyMenu = makeReadyMenu
        self.menuActionCarrier = MenuActionCarrier(openScreenCaptureSettings)
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
        let window = guideWindow ?? makeGuideWindow()
        window.update(status: monitor.status)
        window.show()
        guideWindow = window
    }

    // MARK: 状态应用（主线程；观察者定时路径已投递主线程）

    private func apply(_ status: PermissionMonitor.Status) {
        statusItem.setShowsWarningDot(!status.isReady)
        refreshMenu(status)

        if !hasDecidedInitialGuide {
            hasDecidedInitialGuide = true
            guard !status.isReady else { return }  // 启动时就绪：不弹（重启后授权生效不再弹）
            let window = makeGuideWindow()
            window.update(status: status)
            window.show()
            guideWindow = window
        } else {
            guideWindow?.update(status: status)  // 已有引导窗跟随推进（检测中…… ⇄ 重启提示）
        }
    }

    /// 重建菜单：就绪 → 注入的全量菜单（票 19）；未就绪 → 占位骨架，重确认态顶部换 §8.4 引导块
    private func refreshMenu(_ status: PermissionMonitor.Status) {
        let menu = status.isReady ? makeReadyMenu() : PlaceholderMenu.build()
        if status.screenCaptureNeedsReconfirm {
            ScreenCaptureReconfirmGuide.install(
                into: menu,
                statusLineTarget: menuActionCarrier,
                action: #selector(MenuActionCarrier.openScreenCaptureSettings)
            )
        }
        statusItem.set(menu: menu)
    }
}
