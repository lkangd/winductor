import AppKit

// WiredMenuBuilder.swift — 全量菜单构建（票 19，spec §8.2 七项定稿结构 + §8.5 能力状态行）。
// 结构（逐字照 09 二）：状态行（纯文本三态）──── 立即恢复／撤销上次恢复 ──── 登录时启动 ✓／
// 打开快照文件夹／打开日志文件夹 ──── 能力状态行 ──── 退出窗口布局恢复器。
// 无「最近结果」常驻行（09 二：完成通知已带计数，常驻只会变陈旧信息）。
// 动作经 NSObject 载体路由到注入闭包（NSMenuItem.target 为 unsafe unretained——载体同时挂在
// 各动作项 representedObject（强引用）上保活，测试直接 perform 捕获）。
// 状态/可用性由调用方在构建时刻判定传入（canUndo／登录勾选态／状态行与能力行文案），构建器不做 IO。

/// 菜单内容与动作（构建时刻的快照态；动作闭包由协调器注入）
public struct WiredMenuContent {
    /// 状态行标题（StatusLineState 判定产物，纯文本）
    public let statusLineTitle: String
    /// 「撤销上次恢复」可用性（RestoreEngine.canUndo()；false = 置灰禁用）
    public let canUndo: Bool
    /// 「登录时启动」勾选态（SMAppService.mainApp.status == .enabled）
    public let loginLaunchChecked: Bool
    /// 能力状态行标题（CapabilityStatusLine 产物，纯文本）
    public let capabilityTitle: String
    public let onRestoreNow: () -> Void
    public let onUndo: () -> Void
    public let onToggleLoginLaunch: () -> Void
    public let onOpenSnapshotsFolder: () -> Void
    public let onOpenLogsFolder: () -> Void

    public init(statusLineTitle: String,
                canUndo: Bool,
                loginLaunchChecked: Bool,
                capabilityTitle: String,
                onRestoreNow: @escaping () -> Void,
                onUndo: @escaping () -> Void,
                onToggleLoginLaunch: @escaping () -> Void,
                onOpenSnapshotsFolder: @escaping () -> Void,
                onOpenLogsFolder: @escaping () -> Void) {
        self.statusLineTitle = statusLineTitle
        self.canUndo = canUndo
        self.loginLaunchChecked = loginLaunchChecked
        self.capabilityTitle = capabilityTitle
        self.onRestoreNow = onRestoreNow
        self.onUndo = onUndo
        self.onToggleLoginLaunch = onToggleLoginLaunch
        self.onOpenSnapshotsFolder = onOpenSnapshotsFolder
        self.onOpenLogsFolder = onOpenLogsFolder
    }
}

public enum WiredMenuBuilder {
    /// 菜单标题（NSStatusItem 不显示，仅作标识；沿票 10 占位菜单同款）
    static let menuTitle = "窗口布局恢复器"

    /// 构建 §8.2 定稿菜单
    public static func build(_ content: WiredMenuContent) -> NSMenu {
        let menu = NSMenu(title: menuTitle)
        menu.autoenablesItems = false  // 可用性全部显式声明（照占位菜单口径）
        let carrier = Carrier(content)  // 动作载体；经各动作项 representedObject 强持有

        // 状态行（纯文本三态，spec §8.2）
        menu.addItem(disabled(content.statusLineTitle))
        menu.addItem(.separator())

        // 恢复动作（票 14–17 引擎经协调器接线）
        menu.addItem(actionItem("立即恢复", #selector(Carrier.restoreNow), carrier))
        // 撤销入口可用性 = canUndo（spec §7.4「仅回滚快照存在时可用」，false 置灰无动作）
        let undo = content.canUndo
            ? actionItem("撤销上次恢复", #selector(Carrier.undoLast), carrier)
            : disabled("撤销上次恢复")
        menu.addItem(undo)
        menu.addItem(.separator())

        // 设置（唯一勾选项，spec 09 三）与 Finder 入口（spec 09 四）
        let login = actionItem("登录时启动", #selector(Carrier.toggleLoginLaunch), carrier)
        login.state = content.loginLaunchChecked ? .on : .off
        menu.addItem(login)
        menu.addItem(actionItem("打开快照文件夹", #selector(Carrier.openSnapshotsFolder), carrier))
        menu.addItem(actionItem("打开日志文件夹", #selector(Carrier.openLogsFolder), carrier))
        menu.addItem(.separator())

        // 能力状态行（纯文本，spec §8.5）
        menu.addItem(disabled(content.capabilityTitle))
        menu.addItem(.separator())

        // 退出（响应链 terminate:，骨架期同款）
        let quit = NSMenuItem(title: "退出窗口布局恢复器",
                              action: NSSelectorFromString("terminate:"),
                              keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.isEnabled = true
        menu.addItem(quit)

        return menu
    }

    // MARK: 动作载体（NSMenuItem target 必须是 NSObject；representedObject 强引用防释放）

    private final class Carrier: NSObject {
        private let content: WiredMenuContent
        init(_ content: WiredMenuContent) { self.content = content }

        @objc func restoreNow() { content.onRestoreNow() }
        @objc func undoLast() { content.onUndo() }
        @objc func toggleLoginLaunch() { content.onToggleLoginLaunch() }
        @objc func openSnapshotsFolder() { content.onOpenSnapshotsFolder() }
        @objc func openLogsFolder() { content.onOpenLogsFolder() }
    }

    /// 可用动作项（target = 载体；representedObject 挂同一载体保活）
    private static func actionItem(_ title: String, _ action: Selector, _ carrier: Carrier) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = carrier
        item.representedObject = carrier
        item.isEnabled = true
        return item
    }

    /// 置灰纯文本项（状态行／能力状态行／禁用的撤销入口）
    private static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
