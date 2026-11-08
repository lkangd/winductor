import AppKit
import Core
import SwiftUI

// PresetManagerWindow.swift — 预设管理窗口的宿主（display-presets spec §6.4，票 07）。
// 单实例：首次 show() 建窗，之后再打开只前置（关闭 = 隐藏，不释放）。
// 实时刷新：打开/激活时、屏幕参数变化时（立即一次 + 2s 后再一次，等拓扑稳定）、外部事件（恢复/保存/撤销完成，
// 经 reloadIfVisible，装配方挂在菜单刷新同一处）重读存储与当前拓扑。
// 对话框生产实现 AlertPresetManagerDialogs（NSAlert；菜单栏 agent 应用须先激活自身）。

public final class PresetManagerWindowController: NSObject, NSWindowDelegate {
    public let model: PresetManagerModel
    private var window: NSWindow?
    private var screenObserver: NSObjectProtocol?
    /// 拓扑稳定后补刷一次的延迟（拔插时 didChangeScreenParameters 先于排列定型）
    private let settleDelay: TimeInterval = 2

    public init(model: PresetManagerModel) {
        self.model = model
        super.init()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    /// 打开或前置窗口（主线程）
    public func show() {
        model.reload()
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 窗口可见时重读（外部事件后调用；主线程）
    public func reloadIfVisible() {
        guard window?.isVisible == true else { return }
        model.reload()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "管理预设"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PresetManagerView(model: model))
        window.setFrameAutosaveName("WinductorPresetManager")
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

    public func windowDidBecomeKey(_ notification: Notification) {
        model.reload()
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
