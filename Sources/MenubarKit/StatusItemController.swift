import AppKit

// StatusItemController.swift — 菜单栏状态项薄封装（票 10 骨架；票 19 全量接线）。
// 职责：拥有 NSStatusItem 生命周期、装占位图标（spec §8.1「正常」态的网格图形族）、挂菜单。
// 图标三态（正常网格／未就绪警示点／恢复中同步）的切换接线归票 19。

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
            accessibilityDescription: "窗口布局恢复器"
        ) else { return }
        statusItem.button?.image = image
    }

    /// 把菜单挂到状态项
    public func set(menu: NSMenu) {
        statusItem.menu = menu
    }

    /// 未就绪警示点开关（spec §8.1「未就绪：同图 + 黄色警示点」；叠加实现见 WarningDotOverlay）。
    /// 恢复中第三态的临时换图归票 19。
    public func setShowsWarningDot(_ visible: Bool) {
        guard let button else { return }
        if visible {
            WarningDotOverlay.show(on: button)
        } else {
            WarningDotOverlay.hide(from: button)
        }
    }
}
