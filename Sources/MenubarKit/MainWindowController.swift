import AppKit
import Core
import SwiftUI

// MainWindowController.swift — 统一主窗口的宿主（ui-refactor 票 03，spec §5.1；取代 display-presets §6.4 的旧窗口宿主）。
// 单实例：首次 show() 建窗，之后再打开只前置（关闭 = 隐藏，不释放）。
// Swish 式外观：.fullSizeContentView + 透明标题栏 + 隐藏标题，红绿灯落在侧栏顶部；可缩放，最小 720×520。
// 红绿灯与内容区 header 标题垂直居中对齐、左缘对齐侧栏菜单行（ui-refactor 票 10，TrafficLightPositioner）。
// 实时刷新（沿用旧窗口时机）：打开/激活时（打开只重读一次，见 skipsNextBecomeKeyReload）、屏幕参数变化时（立即一次 + 2s 后再一次，等拓扑稳定）、外部事件（恢复/保存/撤销完成，
// 经 reloadIfVisible，装配方挂在菜单刷新同一处）重读存储、当前拓扑与菜单现状。
// 对话框生产实现 AlertPresetManagerDialogs（NSAlert；菜单栏 agent 应用须先激活自身）。

public final class MainWindowController: NSObject, NSWindowDelegate {
    /// 最小内容尺寸（spec §5.1「最小约 720×520」）
    static let minimumSize = NSSize(width: 720, height: 520)
    /// 首次打开的默认尺寸（原型同款）
    static let defaultSize = NSSize(width: 860, height: 640)

    public let model: MainWindowModel
    private(set) var window: NSWindow?
    /// 红绿灯定位（随窗口常驻）
    private var trafficLights: TrafficLightPositioner?
    private var screenObserver: NSObjectProtocol?
    /// 拓扑稳定后补刷一次的延迟（拔插时 didChangeScreenParameters 先于排列定型）
    private let settleDelay: TimeInterval
    /// 前置呈现（生产：激活本应用 + makeKeyAndOrderFront；测试注入离屏呈现）
    private let present: (NSWindow) -> Void
    /// show() 已重读、呈现随后让窗口成为 key：吞掉这一次 windowDidBecomeKey 的重读（打开只重读一次；
    /// 激活可能异步，故按「下一次成为 key」而非呈现返回时清除；窗口本已是 key 则不会再收到，不置位）
    private var skipsNextBecomeKeyReload = false

    public convenience init(model: MainWindowModel) {
        self.init(model: model, settleDelay: 2) { window in
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    init(model: MainWindowModel, settleDelay: TimeInterval, present: @escaping (NSWindow) -> Void) {
        self.model = model
        self.settleDelay = settleDelay
        self.present = present
        super.init()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// 打开或前置窗口，停在上次的页（主线程）
    public func show() {
        model.reload()
        let window = self.window ?? makeWindow()
        self.window = window
        skipsNextBecomeKeyReload = !window.isKeyWindow
        present(window)
        trafficLights?.apply()  // 重新显示兜底（复位本会经 frame 变化通知改回）
    }

    /// 打开或前置窗口并选中当前拓扑（菜单「管理预设…」；当前拓扑无预设也落在其页）
    public func showCurrentTopology() {
        model.selectCurrentTopology()
        show()
    }

    /// 窗口可见时重读（外部事件后调用；主线程）
    public func reloadIfVisible() {
        guard window?.isVisible == true else { return }
        model.reload()
    }

    /// 窗口形态：透明全尺寸标题栏，内容铺满整窗
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]

    /// 窗口外观配置 + 装入宿主 + 红绿灯定位（离屏渲染 harness 复用，保证与真窗口同一几何）。返回的定位器须由调用方持有
    static func install(_ host: NSView, in window: NSWindow) -> TrafficLightPositioner {
        window.title = "Winductor"  // 不显示；窗口菜单 / 调度中心 / 辅助功能用
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = minimumSize
        window.contentView = host
        return TrafficLightPositioner(window: window, leading: MainWindowMetrics.sidebarRowInset,
                                      barHeight: MainWindowMetrics.headerHeight)
    }

    private func makeWindow() -> NSWindow {
        let window = MainAppWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: Self.styleMask, backing: .buffered, defer: false)
        trafficLights = Self.install(NSHostingView(rootView: MainWindowView(model: model)), in: window)
        window.setFrameAutosaveName("WinductorMainWindow")
        if window.frame.width < Self.minimumSize.width || window.frame.height < Self.minimumSize.height {
            window.setContentSize(Self.defaultSize)
        }
        window.center()
        window.delegate = self
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                reloadIfVisible()
                DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in self?.reloadIfVisible() }
            }
        return window
    }

    /// 激活时重读（切回本窗口）；show() 刚重读过的那一次跳过
    public func windowDidBecomeKey(_ notification: Notification) {
        guard !skipsNextBecomeKeyReload else {
            skipsNextBecomeKeyReload = false
            return
        }
        model.reload()
    }

    /// 关闭 = 隐藏：呈现后从未成为 key 的跳过标记不留到下次
    public func windowWillClose(_ notification: Notification) {
        skipsNextBecomeKeyReload = false
    }
}

/// 菜单栏 agent 没有默认的「文件 > 关闭」菜单：由当前窗口处理标准关闭快捷键，
/// 不装全局 event monitor，避免吞掉其他窗口或输入框的按键。
private final class MainAppWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.type == .keyDown, modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 生产对话框：NSAlert（改名/别名带单行文本框）
public final class AlertPresetManagerDialogs: PresetManagerDialogs {
    public init() {}

    public func promptRename(currentName: String, message: String?) -> String? {
        promptText(title: "重命名预设", message: message ?? "同一屏幕排列下预设名称不能重复。",
                   isWarning: message != nil, value: currentName, placeholder: nil, confirm: "重命名")
    }

    public func promptAlias(currentAlias: String?, placeholder: String) -> String? {
        promptText(title: "修改屏幕排列名称", message: "留空则显示默认名称「\(placeholder)」。",
                   isWarning: false, value: currentAlias ?? "", placeholder: placeholder, confirm: "保存")
    }

    public func confirmDelete(presetName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "删除预设「\(presetName)」？"
        alert.informativeText = "此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func promptText(title: String, message: String, isWarning: Bool, value: String,
                            placeholder: String?, confirm: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = isWarning ? .warning : .informational
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
