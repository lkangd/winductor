import AppKit

// 菜单构建器只呈现当前屏幕排列的内容；动作闭包由协调器注入。
// 每个动作载体挂在 representedObject 上保活（NSMenuItem.target 不强持有）。

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
    /// 「保存新预设」可用性（SavePresetFlow.availability() == .available）
    public let canSavePreset: Bool
    /// 「恢复预设 ▸」子菜单项（当前拓扑预设；空 = 整项置灰）
    public let restorePresets: [RestorePresetMenuEntry]
    /// 「撤销上次恢复」可用性（RestoreEngine.canUndo()；false = 置灰禁用）
    public let canUndo: Bool
    /// 能力状态行标题（CapabilityStatusLine 产物，纯文本）
    public let capabilityTitle: String
    public let onSavePreset: (() -> Void)?
    /// 参数 = 预设 id
    public let onRestorePreset: ((String) -> Void)?
    public let onUndo: () -> Void
    /// 打开主窗口（nil = 未装配，项置灰）
    public let onManagePresets: (() -> Void)?
    public let onOpenSettings: (() -> Void)?
    /// 「覆盖预设 ▸」可用性（与保存同口径）
    public let canOverwritePreset: Bool
    /// 覆盖当前拓扑下的指定预设，参数 = 预设 id（nil = 未装配，置灰）
    public let onOverwritePreset: ((String) -> Void)?

    public init(statusLineTitle: String,
                canSavePreset: Bool,
                restorePresets: [RestorePresetMenuEntry],
                canUndo: Bool,
                capabilityTitle: String,
                onSavePreset: (() -> Void)?,
                onRestorePreset: ((String) -> Void)?,
                onUndo: @escaping () -> Void,
                onManagePresets: (() -> Void)?,
                canOverwritePreset: Bool = false,
                onOverwritePreset: ((String) -> Void)? = nil,
                onOpenSettings: (() -> Void)? = nil) {
        self.statusLineTitle = statusLineTitle
        self.canSavePreset = canSavePreset
        self.restorePresets = restorePresets
        self.canUndo = canUndo
        self.capabilityTitle = capabilityTitle
        self.onSavePreset = onSavePreset
        self.onRestorePreset = onRestorePreset
        self.onUndo = onUndo
        self.onManagePresets = onManagePresets
        self.onOpenSettings = onOpenSettings
        self.canOverwritePreset = canOverwritePreset
        self.onOverwritePreset = onOverwritePreset
    }
}

public enum WiredMenuBuilder {
    /// 菜单标题（NSStatusItem 不显示，仅作标识；沿票 10 占位菜单同款）
    static let menuTitle = "Winductor"

    /// 构建定稿菜单（docs/handoffs/menubar-menu-refresh.md）
    public static func build(_ content: WiredMenuContent) -> NSMenu {
        let menu = NSMenu(title: menuTitle)
        menu.autoenablesItems = false  // 可用性全部显式声明（照占位菜单口径）

        // 状态行（纯文本四态，spec §6.1）
        menu.addItem(disabled(content.statusLineTitle))
        menu.addItem(.separator())

        // 预设动作：保存（未就绪/镜像中/恢复中置灰）、恢复（子菜单）、撤销（仅回滚快照存在时可用）
        menu.addItem(savePresetItem(content))
        menu.addItem(restorePresetItem(content))
        menu.addItem(item("撤销上次恢复", content.canUndo ? content.onUndo : nil))
        menu.addItem(.separator())

        // 主窗口入口（ui-refactor 票 03）
        menu.addItem(item("管理预设…", content.onManagePresets))
        menu.addItem(item("设置", content.onOpenSettings))
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
        guard !content.restorePresets.isEmpty, let onRestore = content.onRestorePreset else {
            parent.isEnabled = false
            return parent
        }
        let submenu = NSMenu(title: "恢复预设")
        submenu.autoenablesItems = false
        for entry in content.restorePresets {
            let title = entry.isAuto ? "\(entry.name)（自动）" : entry.name
            submenu.addItem(item(title, { onRestore(entry.id) }))
        }
        parent.submenu = submenu
        parent.isEnabled = true
        return parent
    }

    /// 保存父菜单始终可展开，使不可用的两个子项仍可发现。
    private static func savePresetItem(_ content: WiredMenuContent) -> NSMenuItem {
        let parent = NSMenuItem(title: "保存预设", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: parent.title)
        submenu.autoenablesItems = false
        submenu.addItem(item("保存新预设", content.canSavePreset ? content.onSavePreset : nil))
        let overwrite = NSMenuItem(title: "覆盖预设", action: nil, keyEquivalent: "")
        if content.canOverwritePreset, !content.restorePresets.isEmpty, let onOverwrite = content.onOverwritePreset {
            let targets = NSMenu(title: overwrite.title)
            targets.autoenablesItems = false
            for entry in content.restorePresets {
                let title = entry.isAuto ? "\(entry.name)（自动）" : entry.name
                targets.addItem(item(title, { onOverwrite(entry.id) }))
            }
            overwrite.submenu = targets
            overwrite.isEnabled = true
        } else {
            overwrite.isEnabled = false
        }
        submenu.addItem(overwrite)
        parent.submenu = submenu
        parent.isEnabled = true
        return parent
    }

    // MARK: 动作项（载体见 ActionCarrier；representedObject 强引用防释放）

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
