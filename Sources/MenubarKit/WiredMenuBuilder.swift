import AppKit

// WiredMenuBuilder.swift — 全量菜单构建（display-presets spec §6.1，票 06；取代票 19 的 §8.2 七项结构）。
// 结构：状态行（纯文本四态）──── 保存当前布局为预设…／恢复预设 ▸／撤销上次恢复 ──── 管理预设… ────
// 登录时启动 ✓／打开预设文件夹／打开日志文件夹 ──── 能力状态行 ──── 退出 Winductor。
// 「恢复预设 ▸」子菜单 = 当前拓扑预设（调用方给定顺序），自动预设标「（自动）」；无预设整项置灰。
// 动作经 NSObject 载体路由到注入闭包（NSMenuItem.target 为 unsafe unretained——每个动作项一个载体，
// 同时挂在该项 representedObject（强引用）上保活，测试直接 perform 捕获）。
// 状态/可用性由调用方在构建时刻判定传入，构建器不做 IO。

/// 「恢复预设 ▸」子菜单的一项（当前拓扑下的一个预设）
public struct RestorePresetMenuEntry: Equatable {
    public let id: String
    public let name: String
    public let isAuto: Bool

    public init(id: String, name: String, isAuto: Bool) {
        self.id = id
        self.name = name
        self.isAuto = isAuto
    }
}

/// 菜单内容与动作（构建时刻的快照态；动作闭包由协调器注入）
public struct WiredMenuContent {
    /// 状态行标题（StatusLineState 判定产物，纯文本）
    public let statusLineTitle: String
    /// 「保存当前布局为预设…」可用性（SavePresetFlow.availability() == .available）
    public let canSavePreset: Bool
    /// 「恢复预设 ▸」子菜单项（当前拓扑预设；空 = 整项置灰）
    public let restorePresets: [RestorePresetMenuEntry]
    /// 「撤销上次恢复」可用性（RestoreEngine.canUndo()；false = 置灰禁用）
    public let canUndo: Bool
    /// 「登录时启动」勾选态（SMAppService.mainApp.status == .enabled）
    public let loginLaunchChecked: Bool
    /// 能力状态行标题（CapabilityStatusLine 产物，纯文本）
    public let capabilityTitle: String
    public let onSavePreset: () -> Void
    /// 参数 = 预设 id
    public let onRestorePreset: (String) -> Void
    public let onUndo: () -> Void
    /// 打开预设管理窗口（nil = 未装配，项置灰）
    public let onManagePresets: (() -> Void)?
    public let onToggleLoginLaunch: () -> Void
    public let onOpenPresetsFolder: () -> Void
    public let onOpenLogsFolder: () -> Void

    public init(statusLineTitle: String,
                canSavePreset: Bool,
                restorePresets: [RestorePresetMenuEntry],
                canUndo: Bool,
                loginLaunchChecked: Bool,
                capabilityTitle: String,
                onSavePreset: @escaping () -> Void,
                onRestorePreset: @escaping (String) -> Void,
                onUndo: @escaping () -> Void,
                onManagePresets: (() -> Void)?,
                onToggleLoginLaunch: @escaping () -> Void,
                onOpenPresetsFolder: @escaping () -> Void,
                onOpenLogsFolder: @escaping () -> Void) {
        self.statusLineTitle = statusLineTitle
        self.canSavePreset = canSavePreset
        self.restorePresets = restorePresets
        self.canUndo = canUndo
        self.loginLaunchChecked = loginLaunchChecked
        self.capabilityTitle = capabilityTitle
        self.onSavePreset = onSavePreset
        self.onRestorePreset = onRestorePreset
        self.onUndo = onUndo
        self.onManagePresets = onManagePresets
        self.onToggleLoginLaunch = onToggleLoginLaunch
        self.onOpenPresetsFolder = onOpenPresetsFolder
        self.onOpenLogsFolder = onOpenLogsFolder
    }
}

public enum WiredMenuBuilder {
    /// 菜单标题（NSStatusItem 不显示，仅作标识；沿票 10 占位菜单同款）
    static let menuTitle = "Winductor"

    /// 构建 spec §6.1 定稿菜单
    public static func build(_ content: WiredMenuContent) -> NSMenu {
        let menu = NSMenu(title: menuTitle)
        menu.autoenablesItems = false  // 可用性全部显式声明（照占位菜单口径）

        // 状态行（纯文本四态，spec §6.1）
        menu.addItem(disabled(content.statusLineTitle))
        menu.addItem(.separator())

        // 预设动作：保存（未就绪/镜像中/恢复中置灰）、恢复（子菜单）、撤销（仅回滚快照存在时可用）
        menu.addItem(item("保存当前布局为预设…", content.canSavePreset ? content.onSavePreset : nil))
        menu.addItem(restorePresetItem(content))
        menu.addItem(item("撤销上次恢复", content.canUndo ? content.onUndo : nil))
        menu.addItem(.separator())

        // 管理窗口入口（窗口本体归票 07）
        menu.addItem(item("管理预设…", content.onManagePresets))
        menu.addItem(.separator())

        // 设置（唯一勾选项）与 Finder 入口
        let login = item("登录时启动", content.onToggleLoginLaunch)
        login.state = content.loginLaunchChecked ? .on : .off
        menu.addItem(login)
        menu.addItem(item("打开预设文件夹", content.onOpenPresetsFolder))
        menu.addItem(item("打开日志文件夹", content.onOpenLogsFolder))
        menu.addItem(.separator())

        // 能力状态行（纯文本）
        menu.addItem(disabled(content.capabilityTitle))
        menu.addItem(.separator())

        // 退出（响应链 terminate:，骨架期同款）
        let quit = NSMenuItem(title: "退出 Winductor",
                              action: NSSelectorFromString("terminate:"),
                              keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.isEnabled = true
        menu.addItem(quit)

        return menu
    }

    /// 「恢复预设 ▸」：子菜单逐项路由预设 id；无预设整项置灰（不挂子菜单）
    private static func restorePresetItem(_ content: WiredMenuContent) -> NSMenuItem {
        let parent = NSMenuItem(title: "恢复预设", action: nil, keyEquivalent: "")
        guard !content.restorePresets.isEmpty else {
            parent.isEnabled = false
            return parent
        }
        let submenu = NSMenu(title: "恢复预设")
        submenu.autoenablesItems = false
        let onRestore = content.onRestorePreset
        for entry in content.restorePresets {
            let title = entry.isAuto ? "\(entry.name)（自动）" : entry.name
            submenu.addItem(item(title, { onRestore(entry.id) }))
        }
        parent.submenu = submenu
        parent.isEnabled = true
        return parent
    }

    // MARK: 动作载体（NSMenuItem target 必须是 NSObject；representedObject 强引用防释放）

    private final class ActionCarrier: NSObject {
        private let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @objc func fire() { handler() }
    }

    /// 动作项：handler 非 nil = 可用（target = 载体，representedObject 挂同一载体保活）；nil = 置灰无动作
    private static func item(_ title: String, _ handler: (() -> Void)?) -> NSMenuItem {
        guard let handler else { return disabled(title) }
        let carrier = ActionCarrier(handler)
        let item = NSMenuItem(title: title, action: #selector(ActionCarrier.fire), keyEquivalent: "")
        item.target = carrier
        item.representedObject = carrier
        item.isEnabled = true
        return item
    }

    /// 置灰纯文本项（状态行／能力状态行／禁用的动作项）
    private static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
