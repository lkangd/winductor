import AppKit

// StatusItemController.swift — 菜单栏状态项薄封装（票 10 骨架；票 19 全量接线；UI 重构票 02 换品牌图标三态）。
// 职责：拥有 NSStatusItem 生命周期、挂菜单、把图标三态上屏（ui-refactor spec §4）：
//   常态 / 恢复中（两图 0.6s 交替，结束即回常态）/ 未就绪（常态图 + 镂空「!」徽记，画进模板图）。
// 态推导与交替计时归 MenuBarIconAnimator（可单测），三帧模板图归 MenuBarIconImages（生成一次后缓存）；
// 原图缺失（如 .app 漏拷）回落 SF Symbol。入口一律主线程归一（恢复链可能在调度队列线程回调）。

/// 状态项图标接缝（常态/恢复中两态；未就绪徽记归 StatusPresenting）
extension StatusItemController: StatusIconControlling {}

public final class StatusItemController {
    private let statusItem: NSStatusItem
    private let animator: MenuBarIconAnimator

    /// 构造即上屏常态图
    public init() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let images = MenuBarIconImages.make()
        self.statusItem = statusItem
        animator = MenuBarIconAnimator { [weak button = statusItem.button] frame in
            button?.image = images?.image(for: frame) ?? Self.fallbackImage(for: frame)
        }
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// 状态项按钮（恢复提示 popover 的锚点）
    public var button: NSStatusBarButton? { statusItem.button }

    /// 把菜单挂到状态项
    public func set(menu: NSMenu) {
        statusItem.menu = menu
    }

    /// 未就绪徽记开关（spec §4.2 未就绪态；未就绪优先于恢复中）
    public func setShowsNotReadyBadge(_ visible: Bool) {
        onMain { $0.animator.setNotReady(visible) }
    }

    /// 原图缺失时的回落图标（SF Symbol 模板图）
    private static func fallbackImage(for frame: MenuBarIconFrame) -> NSImage? {
        let name = switch frame {
        case .idle: "square.grid.3x3"
        case .restoring: "arrow.triangle.2.circlepath"
        case .notReady: "exclamationmark.triangle"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: "Winductor")
    }

    private func onMain(_ work: @escaping (StatusItemController) -> Void) {
        if Thread.isMainThread {
            work(self)
        } else {
            DispatchQueue.main.async { [weak self] in self.map(work) }
        }
    }
}

// MARK: - StatusIconControlling（常态 ⇄ 恢复中；主线程归一，
// 触发链可能在调度队列线程调装饰器——主队列 FIFO 保证「结束即回」顺序）

extension StatusItemController {
    public func showNormalIcon() {
        onMain { $0.animator.setRestoring(false) }
    }

    public func showRestoringIcon() {
        onMain { $0.animator.setRestoring(true) }
    }
}
