import AppKit

// StatusItemController.swift — 菜单栏状态项薄封装（票 10 骨架；票 19 全量接线）。
// 职责：拥有 NSStatusItem 生命周期、装占位图标（spec §8.1「正常」态的网格图形族）、挂菜单。
// 图标三态（正常网格／未就绪警示点／恢复中同步）的切换接线归票 19。

/// 状态项图标接缝（票 19 §8.1 三态中的常态/恢复中两态；未就绪警示点归 StatusPresenting）
extension StatusItemController: StatusIconControlling {}

public final class StatusItemController {
    /// 占位图标 SF Symbol（网格类，spec §8.1；具体符号实现定，票 19 可换）
    static let placeholderSymbolName = "square.grid.3x3"

    /// 未就绪警示点子视图标识（§8.1「同图 + 黄色警示点」；实现在 WarningDotOverlay，测试按此查找）
    public static let warningDotIdentifier = WarningDotOverlay.identifier

    private let statusItem: NSStatusItem

    public init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// 状态项按钮（未就绪警示点叠加在此；票 19 图标三态接线也经此观察）
    public var button: NSStatusBarButton? { statusItem.button }

    /// 显示占位图标（网格类 SF Symbol）
    public func showPlaceholderIcon() {
        guard let image = NSImage(
            systemSymbolName: Self.placeholderSymbolName,
            accessibilityDescription: "Winductor"
        ) else { return }
        statusItem.button?.image = image
    }

    /// 恢复中图标（§8.1 第三态：临时同步图形，恢复结束由装饰器换回常态 showNormalIcon）
    static let restoringSymbolName = "arrow.triangle.2.circlepath"

    /// 把菜单挂到状态项
    public func set(menu: NSMenu) {
        statusItem.menu = menu
    }

    /// 未就绪警示点开关（spec §8.1「未就绪：同图 + 黄色警示点」；叠加实现见 WarningDotOverlay）。
    /// 恢复中第三态的临时换图归 StatusIconControlling/showRestoringIcon。
    public func setShowsWarningDot(_ visible: Bool) {
        guard let button else { return }
        if visible {
            WarningDotOverlay.show(on: button)
        } else {
            WarningDotOverlay.hide(from: button)
        }
    }
}

// MARK: - StatusIconControlling（票 19 §8.1：常态 ⇄ 恢复中；主线程归一，
// 触发链可能在调度队列线程调装饰器——主队列 FIFO 保证「结束即回」顺序）

extension StatusItemController {
    public func showNormalIcon() {
        showPlaceholderIcon()
    }

    public func showRestoringIcon() {
        setButtonImage(named: Self.restoringSymbolName, description: "恢复中")
    }

    private func setButtonImage(named symbolName: String, description: String) {
        let work = { [weak button] in
            guard let button,
                  let image = NSImage(systemSymbolName: symbolName,
                                      accessibilityDescription: description) else { return }
            button.image = image
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
