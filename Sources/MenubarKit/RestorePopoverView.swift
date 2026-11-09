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

/// 两种 popover 共用的排版规格（display-presets 票 14：原生 popover 观感——统一左缘与内边距、固定宽度、
/// 标题 / 正文 / 附注三级字号与颜色、按钮同宽靠右）
private enum PopoverLayout {
    /// 内容列宽（固定；所有文本行撑满此宽，左缘一致）
    static let contentWidth: CGFloat = 288
    static let insets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
    /// 按钮最小宽（同一行按钮取同宽，至少此宽）
    static let minButtonWidth: CGFloat = 72

    enum TextStyle {
        /// 标题：13pt 半粗、主色
        case title
        /// 正文：13pt、主色（单预设名）
        case body
        /// 说明：12pt、次要色（计数、摘要、单选引导语）
        case secondary
        /// 附注：11pt、次要色（降级附注）
        case note
        /// 警示：12pt、橙色（Space 不足）
        case warning
    }

    static func label(_ text: String, _ style: TextStyle) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        switch style {
        case .title: label.font = .systemFont(ofSize: 13, weight: .semibold); label.textColor = .labelColor
        case .body: label.font = .systemFont(ofSize: 13); label.textColor = .labelColor
        case .secondary: label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
        case .note: label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
        case .warning: label.font = .systemFont(ofSize: 12); label.textColor = .systemOrange
        }
        label.preferredMaxLayoutWidth = contentWidth
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return label
    }

    static func button(_ title: String, _ action: ButtonAction) -> NSButton {
        let button = FirstMouseButton(title: title, target: action, action: #selector(ButtonAction.fire))
        button.bezelStyle = .push
        button.controlSize = .regular
        return button
    }

    static func radio(_ title: String, _ action: ButtonAction) -> NSButton {
        let button = FirstMouseButton(radioButtonWithTitle: title, target: action, action: #selector(ButtonAction.fire))
        button.font = .systemFont(ofSize: 13)
        return button
    }

    static func stack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    /// 底部按钮行：撑满内容列宽、按钮靠右且同宽（最右为主操作）
    static func buttonRow(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        // 左侧弹性留白把按钮推到右缘（留白最易拉伸，按钮保持内容宽）
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.insertView(spacer, at: 0, in: .leading)
        var constraints = [row.widthAnchor.constraint(equalToConstant: contentWidth)]
        for button in buttons {
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            constraints.append(button.widthAnchor.constraint(greaterThanOrEqualToConstant: minButtonWidth))
            if let first = buttons.first, first !== button {
                constraints.append(button.widthAnchor.constraint(equalTo: first.widthAnchor))
            }
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    /// 根栈铺满宿主视图（宽度 = 内容列 + 左右内边距）
    static func install(_ root: NSStackView, in host: NSView) {
        root.edgeInsets = insets
        root.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            root.topAnchor.constraint(equalTo: host.topAnchor),
            root.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: contentWidth + insets.left + insets.right),
        ])
    }
}

/// 恢复提示（§6.2）：拓扑名、预设单选（单预设直接显示名称）、所选预设摘要与 Space 不足提示、「忽略」/「恢复」
final class RestorePromptView: NSView {
    private(set) var content: RestorePromptContent
    private let onEvent: (RestorePopoverEvent) -> Void
    private var actions: [ButtonAction] = []
    private var radios: [(presetID: String, button: NSButton)] = []
    private let detail = PopoverLayout.stack([], spacing: 3)

    init(content: RestorePromptContent, onEvent: @escaping (RestorePopoverEvent) -> Void) {
        self.content = content
        self.onEvent = onEvent
        super.init(frame: .zero)

        let title = PopoverLayout.label(content.title, .title)
        var rows: [NSView] = [title]
        var pickerTail: NSView = title
        if content.showsPicker {
            let caption = PopoverLayout.label("选择要恢复的预设：", .secondary)
            rows.append(caption)
            let radioStack = PopoverLayout.stack([], spacing: 6)
            for option in content.options {
                let action = ButtonAction { [weak self] in self?.onEvent(.select(presetID: option.presetID)) }
                let radio = PopoverLayout.radio(option.name, action)
                actions.append(action)
                radios.append((option.presetID, radio))
                radioStack.addArrangedSubview(radio)
            }
            rows.append(radioStack)
            pickerTail = radioStack
        } else if let only = content.selected {
            let name = PopoverLayout.label("预设：\(only.name)", .body)
            rows.append(name)
            pickerTail = name
        }
        rows.append(detail)

        let ignore = ButtonAction { [weak self] in self?.onEvent(.ignoreTapped) }
        let restore = ButtonAction { [weak self] in self?.onEvent(.restoreTapped) }
        actions += [ignore, restore]
        let restoreButton = PopoverLayout.button("恢复", restore)
        restoreButton.keyEquivalent = "\r"
        let buttonRow = PopoverLayout.buttonRow([PopoverLayout.button("忽略", ignore), restoreButton])
        rows.append(buttonRow)

        let root = PopoverLayout.stack(rows, spacing: 8)
        root.setCustomSpacing(10, after: title)
        root.setCustomSpacing(10, after: pickerTail)
        root.setCustomSpacing(14, after: detail)
        PopoverLayout.install(root, in: self)
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
        selected.summaryLines.forEach { detail.addArrangedSubview(PopoverLayout.label($0, .secondary)) }
        if let lastSummary = detail.arrangedSubviews.last, !selected.shortageLines.isEmpty {
            detail.setCustomSpacing(6, after: lastSummary)
        }
        selected.shortageLines.forEach { detail.addArrangedSubview(PopoverLayout.label($0, .warning)) }
    }
}

/// 自动恢复告知（§6.3）：标题「已按『X』恢复」、计数、降级附注（次要小字）；底部「改用其他预设…」「撤销」同宽靠右
final class AutoRestoreNoticeView: NSView {
    private var actions: [ButtonAction] = []

    init(content: AutoRestoreNoticeContent, onEvent: @escaping (RestorePopoverEvent) -> Void) {
        super.init(frame: .zero)
        let headline = PopoverLayout.label(content.headline, .title)
        let detail = PopoverLayout.label(content.detail, .secondary)
        var rows: [NSView] = [headline, detail]
        if let note = content.degradeNote {
            rows.append(PopoverLayout.label(note, .note))
        }

        var buttons: [NSButton] = []
        if content.showsSwitchPreset {
            let switchPreset = ButtonAction { onEvent(.switchPresetTapped) }
            actions.append(switchPreset)
            buttons.append(PopoverLayout.button("改用其他预设…", switchPreset))
        }
        if content.showsUndo {
            let undo = ButtonAction { onEvent(.undoTapped) }
            actions.append(undo)
            buttons.append(PopoverLayout.button("撤销", undo))
        }
        let textTail = rows.last!
        if !buttons.isEmpty { rows.append(PopoverLayout.buttonRow(buttons)) }

        let root = PopoverLayout.stack(rows, spacing: 3)
        root.setCustomSpacing(4, after: headline)
        root.setCustomSpacing(14, after: textTail)
        PopoverLayout.install(root, in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
}
