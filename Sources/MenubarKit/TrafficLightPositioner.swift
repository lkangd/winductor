import AppKit

// TrafficLightPositioner.swift — 主窗口红绿灯定位（ui-refactor 票 10）。
// 目标：三个按钮的垂直中心与内容区 header 标题中心对齐（距窗顶 barHeight / 2 = 25），关闭按钮左缘 = 侧栏菜单行高亮底左缘
// （leading = 10），按钮间距沿用系统值。
// 做法：把标题栏容器（按钮的祖父视图）加高到 header 高度、按钮在其中垂直居中——按钮须整个落在容器内才点得中。
// 不用工具栏 / 标题栏附件：.unified 工具栏能加高标题栏并让按钮居中，但高度与按钮 x 由系统定（随版本变），对不准 25 / 10；
// 附件视图不能移动系统按钮。
// 保持：AppKit 在缩放、进出全屏、激活态变化、重新显示等布局时会把容器与按钮复位到系统默认位。对容器、标题栏视图与三个按钮
// 开 postsFrameChangedNotifications，任何复位都同步收到 frameDidChange 并当场改回（发生在同一次布局内，绘制前已就位、不闪）；
// 另挂窗口缩放 / 退出全屏 / key 变化 / 换屏通知兜底；视图层级被系统换掉时按新视图重新绑定。
// 全屏时不干预（全屏标题栏是系统自动显隐的条，交给系统），退出全屏后复原。只设与目标不同的 frame，复位—改回的往返有界。

final class TrafficLightPositioner {
    private static let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    private static let windowEvents: [Notification.Name] = [
        NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification,
        NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification,
        NSWindow.didChangeBackingPropertiesNotification,
    ]

    private weak var window: NSWindow?
    /// 关闭按钮左缘（窗口坐标）
    private let leading: CGFloat
    /// 标题栏容器高度 = header 高度；按钮在其中垂直居中
    private let barHeight: CGFloat
    /// 相邻按钮左缘之差：取系统初始布局的值
    private var spacing: CGFloat?
    private var boundViews: [ObjectIdentifier] = []
    private var viewObservers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []
    /// 本类自己改 frame 时同步发出的 frameDidChange 不再重入
    private var isApplying = false

    init(window: NSWindow, leading: CGFloat, barHeight: CGFloat) {
        self.window = window
        self.leading = leading
        self.barHeight = barHeight
        windowObservers = Self.windowEvents.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                self?.apply()
            }
        }
        apply()
    }

    deinit {
        (windowObservers + viewObservers).forEach(NotificationCenter.default.removeObserver)
    }

    /// 把标题栏容器与红绿灯放到目标位（幂等；全屏时不动）
    func apply() {
        guard !isApplying, let window, !window.styleMask.contains(.fullScreen) else { return }
        let buttons = Self.buttonTypes.compactMap { window.standardWindowButton($0) }
        guard buttons.count == Self.buttonTypes.count, let titlebar = buttons[0].superview,
              buttons.allSatisfy({ $0.superview === titlebar }),
              let container = titlebar.superview, let frameView = container.superview else { return }
        isApplying = true
        defer { isApplying = false }
        let spacing = spacing ?? buttons[1].frame.minX - buttons[0].frame.minX
        self.spacing = spacing
        bind([container, titlebar] + buttons)

        let containerFrame = NSRect(x: 0, y: frameView.isFlipped ? 0 : frameView.bounds.height - barHeight,
                                    width: frameView.bounds.width, height: barHeight)
        if container.frame != containerFrame { container.frame = containerFrame }
        if titlebar.frame != container.bounds { titlebar.frame = container.bounds }
        // 标题栏视图里的 x 与窗口坐标一致（容器贴窗口左缘）；垂直居中与坐标系翻转无关
        for (index, button) in buttons.enumerated() {
            let origin = NSPoint(x: leading + CGFloat(index) * spacing, y: (barHeight - button.frame.height) / 2)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    /// 观察这些视图的 frame 变化（系统换了视图则重新绑定）
    private func bind(_ views: [NSView]) {
        let ids = views.map(ObjectIdentifier.init)
        guard ids != boundViews else { return }
        viewObservers.forEach(NotificationCenter.default.removeObserver)
        boundViews = ids
        viewObservers = views.map { view in
            view.postsFrameChangedNotifications = true
            return NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view,
                                                          queue: nil) { [weak self] _ in self?.apply() }
        }
    }
}
