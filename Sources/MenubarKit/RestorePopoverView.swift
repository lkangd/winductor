import AppKit

// RestorePopoverView.swift — 恢复提示 / 自动恢复告知的 AppKit 呈现（display-presets spec §6.2/§6.3），只做排版与点击回传。
// 规则全在 RestorePopoverState / RestorePopoverModel；这里不判断、不读状态。
// 焦点：不激活本应用（不抢当前应用焦点）；按钮 acceptsFirstMouse，未激活时第一下点击即生效。

/// 呈现器：锚定菜单栏状态项按钮的 NSPopover（多屏时随按钮出现在菜单栏所在屏）
public final class StatusItemPopoverPresenter: NSObject, RestorePopoverRendering, NSPopoverDelegate {
    public var onEvent: ((RestorePopoverEvent) -> Void)?
    private let anchor: () -> NSView?
    private var popover: NSPopover?
    private var promptView: RestorePromptView?

    /// - Parameter anchor: 锚点视图（生产：StatusItemController.button）
    public init(anchor: @escaping () -> NSView?) {
        self.anchor = anchor
    }

    public func render(_ presentation: RestorePopoverPresentation) {
        switch presentation {
        case .hidden:
            close()
        case .prompt(let content):
            // 同一提示内切换单选：原位更新，不重弹
            if let promptView, popover?.isShown == true, promptView.content.topologyKey == content.topologyKey,
               promptView.content.options == content.options {
                promptView.update(content)
                return
            }
            let view = RestorePromptView(content: content) { [weak self] in self?.onEvent?($0) }
            show(view)
            promptView = view
        case .notice(let content, _):
            show(AutoRestoreNoticeView(content: content) { [weak self] in self?.onEvent?($0) })
        }
    }

    /// 每次新内容重新锚定（拓扑变化后状态项按钮可能换了屏）
    private func show(_ view: NSView) {
        close()
        guard let anchor = anchor(), anchor.window != nil else { return }
        let controller = NSViewController()
        controller.view = view
        let popover = NSPopover()
        popover.behavior = .applicationDefined  // 提示不自动消失；告知由到期调度收起
        popover.animates = true
        popover.contentViewController = controller
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private func close() {
        let current = popover
        popover = nil
        promptView = nil
        current?.close()
    }

    /// 系统替我们关掉（锚点消失等）：同步状态机为收起
    public func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        popover = nil
        promptView = nil
        onEvent?(.dismiss)
    }
}

/// 未激活应用里第一下点击即生效（不先激活本应用再要第二下）
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// target/action 载体（NSButton 闭包回调）
private final class ButtonAction: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

private enum PopoverLayout {
    static let width: CGFloat = 300

    static func label(_ text: String, bold: Bool = false, secondary: Bool = false,
                      color: NSColor? = nil) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = bold ? .boldSystemFont(ofSize: NSFont.systemFontSize)
            : .systemFont(ofSize: secondary ? NSFont.smallSystemFontSize : NSFont.systemFontSize)
        label.textColor = color ?? (secondary ? .secondaryLabelColor : .labelColor)
        label.preferredMaxLayoutWidth = width
        return label
    }

    static func button(_ title: String, _ action: ButtonAction, radio: Bool = false) -> NSButton {
        let button = FirstMouseButton(title: title, target: action, action: #selector(ButtonAction.fire))
        if radio { button.setButtonType(.radio) } else { button.bezelStyle = .rounded }
        return button
    }

    static func stack(_ views: [NSView], vertical: Bool = true, spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = spacing
        return stack
    }
}

/// 恢复提示（§6.2）：拓扑名、预设单选（单预设直接显示名称）、所选预设摘要与 Space 不足提示、「忽略」/「恢复」
final class RestorePromptView: NSView {
    private(set) var content: RestorePromptContent
    private let onEvent: (RestorePopoverEvent) -> Void
    private var actions: [ButtonAction] = []
    private var radios: [(presetID: String, button: NSButton)] = []
    private let detail = PopoverLayout.stack([], spacing: 4)

    init(content: RestorePromptContent, onEvent: @escaping (RestorePopoverEvent) -> Void) {
        self.content = content
        self.onEvent = onEvent
        super.init(frame: .zero)

        var rows: [NSView] = [PopoverLayout.label(content.title, bold: true)]
        if content.showsPicker {
            rows.append(PopoverLayout.label("选择要恢复的预设：", secondary: true))
            for option in content.options {
                let action = ButtonAction { [weak self] in self?.onEvent(.select(presetID: option.presetID)) }
                let radio = PopoverLayout.button(option.name, action, radio: true)
                actions.append(action)
                radios.append((option.presetID, radio))
                rows.append(radio)
            }
        } else if let only = content.selected {
            rows.append(PopoverLayout.label("预设：\(only.name)"))
        }
        rows.append(detail)

        let ignore = ButtonAction { [weak self] in self?.onEvent(.ignoreTapped) }
        let restore = ButtonAction { [weak self] in self?.onEvent(.restoreTapped) }
        actions += [ignore, restore]
        let restoreButton = PopoverLayout.button("恢复", restore)
        restoreButton.keyEquivalent = "\r"
        let buttonRow = PopoverLayout.stack([NSView(), PopoverLayout.button("忽略", ignore), restoreButton],
                                            vertical: false)
        rows.append(buttonRow)

        let root = PopoverLayout.stack(rows, spacing: 10)
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor), root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor), root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: PopoverLayout.width + 32),
            buttonRow.widthAnchor.constraint(equalToConstant: PopoverLayout.width),
        ])
        update(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// 单选切换后原位刷新（选中态 + 摘要 + Space 不足）
    func update(_ content: RestorePromptContent) {
        self.content = content
        for (presetID, radio) in radios {
            radio.state = presetID == content.selectedPresetID ? .on : .off
        }
        detail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let selected = content.selected else { return }
        selected.summaryLines.forEach { detail.addArrangedSubview(PopoverLayout.label($0, secondary: true)) }
        selected.shortageLines.forEach {
            detail.addArrangedSubview(PopoverLayout.label($0, secondary: true, color: .systemOrange))
        }
    }
}

/// 自动恢复告知（§6.3）：「已按「X」恢复」+「撤销」、计数与降级附注、（有其他预设时）「改用其他预设…」
final class AutoRestoreNoticeView: NSView {
    private var actions: [ButtonAction] = []

    init(content: AutoRestoreNoticeContent, onEvent: @escaping (RestorePopoverEvent) -> Void) {
        super.init(frame: .zero)
        var headline: [NSView] = [PopoverLayout.label(content.headline, bold: true)]
        if content.showsUndo {
            let undo = ButtonAction { onEvent(.undoTapped) }
            actions.append(undo)
            headline.append(PopoverLayout.button("撤销", undo))
        }
        var rows: [NSView] = [PopoverLayout.stack(headline, vertical: false),
                              PopoverLayout.label(content.detail, secondary: true)]
        if content.showsSwitchPreset {
            let switchPreset = ButtonAction { onEvent(.switchPresetTapped) }
            actions.append(switchPreset)
            let button = PopoverLayout.button("改用其他预设…", switchPreset)
            button.bezelStyle = .inline
            rows.append(button)
        }
        let root = PopoverLayout.stack(rows, spacing: 6)
        root.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor), root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor), root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.widthAnchor.constraint(lessThanOrEqualToConstant: PopoverLayout.width + 32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
}
