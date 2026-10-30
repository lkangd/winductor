import AppKit

// PermissionGuideWindow.swift — 首启授权引导窗（票 18，spec §8.3，独立窗口、硬前置）。
// 文案照 §8.3 全文逐字（测试以独立字面量锁定）：两项授权说明 + 各自【打开系统设置】
// 深链按钮；每 2s 由 PermissionMonitor 状态推进（update(status:)）；
// 两项齐备后显示「✓ 两项授权已齐备。请重启应用使授权生效。」+【立即重启】。
// 窗口不随权限就绪自动关闭——重启提示是用户需要看到的终态。

public final class PermissionGuideWindow {
    // MARK: 呈现观察接缝（测试与票 19 复用）

    /// 引导窗本体（独立窗口，非状态项菜单）
    public let window: NSWindow
    /// 内容文本标签（构造序：标题、导语、①、指引①、②、指引②、状态行）
    public private(set) var contentLabels: [NSTextField]
    /// 两个【打开系统设置】按钮（顺序：①辅助功能、②屏幕与系统录音）
    public private(set) var settingsButtons: [NSButton]
    /// 【立即重启】按钮
    public let restartButton: NSButton
    /// 【立即重启】标题（§8.3 按钮文案）
    public var restartButtonTitle: String { restartButton.title }

    private let statusLabel: NSTextField
    /// 状态行当前文案
    public var statusText: String { statusLabel.stringValue }
    /// 【立即重启】是否可见（未就绪隐藏）
    public var isRestartButtonVisible: Bool { !restartButton.isHidden }

    /// §8.3 状态行两态文案
    static let detectingText = "检测中……"
    static let readyText = "✓ 两项授权已齐备。请重启应用使授权生效。"

    /// target/action 载体：闭包挂 NSButton 需要存活的目标对象（init 强持有）
    private final class ActionCarrier: NSObject {
        private let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func runAction() { handler() }
    }

    private let carriers: [ActionCarrier]

    public init(openSettings: @escaping (PermissionMonitor.Kind) -> Void = SystemSettingsOpener.open,
                relaunch: @escaping () -> Void = { SelfRelauncher.perform() }) {
        let accessibilityCarrier = ActionCarrier { openSettings(.accessibility) }
        let screenCaptureCarrier = ActionCarrier { openSettings(.screenCapture) }
        let restartCarrier = ActionCarrier(relaunch)
        carriers = [accessibilityCarrier, screenCaptureCarrier, restartCarrier]

        // MARK: 文本（§8.3 逐字）

        func text(_ string: String, bold: Bool = false, size: CGFloat = NSFont.systemFontSize) -> NSTextField {
            let label = NSTextField(labelWithString: string)
            label.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
            label.lineBreakMode = .byWordWrapping
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
            return label
        }

        let heading = text("先授权，才能开始", bold: true, size: 16)
        let intro = text("本应用需要两项系统权限才能读取和移动窗口。授权仅用于本机恢复窗口，不上传任何数据。")
        let section1 = text("① 辅助功能 —— 用于读取和设置窗口位置、最小化与全屏。")
        let hint1 = text("→ 隐私与安全性 > 辅助功能，打开「窗口布局恢复器」")
        let section2 = text("② 屏幕与系统录音 —— 用于读取所有屏幕、所有桌面上的窗口列表与标题。")
        let hint2 = text("→ 隐私与安全性 > 屏幕与系统录音，打开「窗口布局恢复器」")
        statusLabel = text(Self.detectingText)
        contentLabels = [heading, intro, section1, hint1, section2, hint2, statusLabel]

        // MARK: 按钮

        let accessibilityButton = NSButton(title: "打开系统设置",
                                           target: accessibilityCarrier,
                                           action: #selector(ActionCarrier.runAction))
        accessibilityButton.bezelStyle = .rounded
        let screenCaptureButton = NSButton(title: "打开系统设置",
                                           target: screenCaptureCarrier,
                                           action: #selector(ActionCarrier.runAction))
        screenCaptureButton.bezelStyle = .rounded
        settingsButtons = [accessibilityButton, screenCaptureButton]

        restartButton = NSButton(title: "立即重启", target: restartCarrier,
                                 action: #selector(ActionCarrier.runAction))
        restartButton.bezelStyle = .rounded
        restartButton.isHidden = true

        // MARK: 布局

        let stack = NSStackView(views: [
            heading,
            intro,
            Self.row(section1, accessibilityButton),
            hint1,
            Self.row(section2, screenCaptureButton),
            hint2,
            Self.row(statusLabel, restartButton),
        ])
        stack.orientation = NSUserInterfaceLayoutOrientation.vertical
        stack.alignment = NSLayoutConstraint.Attribute.leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "先授权，才能开始"
        window.contentView = stack
        window.center()
    }

    /// 行容器：主文本 + 行尾按钮
    private static func row(_ label: NSTextField, _ button: NSButton) -> NSView {
        let pair = NSStackView(views: [label, button])
        pair.orientation = NSUserInterfaceLayoutOrientation.horizontal
        pair.alignment = NSLayoutConstraint.Attribute.firstBaseline
        pair.spacing = 12
        return pair
    }

    // MARK: 状态推进（PermissionMonitor 每 2s 回调驱动）

    /// 依据权限现状推进界面：检测中…… ⇄ 齐备重启提示（§8.3）
    public func update(status: PermissionMonitor.Status) {
        if status.isReady {
            statusLabel.stringValue = Self.readyText
            restartButton.isHidden = false
        } else {
            statusLabel.stringValue = Self.detectingText
            restartButton.isHidden = true
        }
    }

    /// 呈现引导窗：浮层前置（accessory 应用无 Dock 图标，需显式激活）
    public func show() {
        window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
