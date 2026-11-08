import AppKit

// PlaceholderMenu.swift — 占位菜单构建（票 10 骨架；未就绪态沿用，就绪态换 WiredMenuBuilder 全量菜单）。
// 结构随 display-presets spec §6.1：状态行 + 保存当前布局为预设…／恢复预设／撤销上次恢复 + 管理预设… +
// 登录时启动／打开预设文件夹／打开日志文件夹 + 能力状态行 + 退出。动作项全部置灰，
// 仅「退出 Winductor」可用（terminate: 响应链）。
// 占位文案带「（占位）」后缀，避免展示假状态。

public enum PlaceholderMenu {
    /// 状态项菜单不显示标题，仅作标识
    static let title = "Winductor"

    /// 构建 §6.1 骨架的占位菜单
    public static func build() -> NSMenu {
        let menu = NSMenu(title: title)
        // 占位项不参与自动启用，可用性全部显式声明
        menu.autoenablesItems = false

        // 状态行占位（就绪后换 StatusLineState 四态；屏幕录制重确认时由 ScreenCaptureReconfirmGuide 替换）
        menu.addItem(disabled("状态行（占位）"))
        menu.addItem(.separator())

        // 预设动作占位
        menu.addItem(disabled("保存当前布局为预设…"))
        menu.addItem(disabled("恢复预设"))
        menu.addItem(disabled("撤销上次恢复"))
        menu.addItem(.separator())
        menu.addItem(disabled("管理预设…"))
        menu.addItem(.separator())

        // 设置与 Finder 入口占位
        menu.addItem(disabled("登录时启动"))
        menu.addItem(disabled("打开预设文件夹"))
        menu.addItem(disabled("打开日志文件夹"))
        menu.addItem(.separator())

        // 能力状态行占位（就绪后换启动探针结果）
        menu.addItem(disabled("能力状态（占位）"))
        menu.addItem(.separator())

        // 退出：骨架期唯一活项
        let quit = NSMenuItem(
            title: "退出 Winductor",
            action: NSSelectorFromString("terminate:"),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = .command
        quit.isEnabled = true
        menu.addItem(quit)

        return menu
    }

    /// 置灰且不挂动作的占位项
    private static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
