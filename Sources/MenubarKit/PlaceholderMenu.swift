import AppKit

// PlaceholderMenu.swift — 占位菜单构建（票 10 骨架；票 19 以真实接线替换占位项）。
// 结构照 spec §8.2 定稿：状态行 + 立即恢复／撤销上次恢复 + 登录时启动／打开快照文件夹／
// 打开日志文件夹 + 能力状态行 + 退出。骨架期动作项全部置灰（引擎未接线），
// 仅「退出窗口布局恢复器」可用（terminate: 响应链）。
// 占位文案带「（占位）」后缀，避免展示假状态；票 19 接线后换 §8.2 真实文案。

public enum PlaceholderMenu {
    /// 状态项菜单不显示标题，仅作标识
    static let title = "窗口布局恢复器"

    /// 构建 §8.2 骨架的占位菜单
    public static func build() -> NSMenu {
        let menu = NSMenu(title: title)
        // 占位项不参与自动启用，可用性全部显式声明
        menu.autoenablesItems = false

        // 状态行占位（spec §8.2 三态之一由票 19 接线：快照就绪／无匹配快照／一屏（拔出））
        menu.addItem(disabled("状态行（占位）"))
        menu.addItem(.separator())

        // 恢复动作占位（票 14–17 引擎接线）
        menu.addItem(disabled("立即恢复"))
        menu.addItem(disabled("撤销上次恢复"))
        menu.addItem(.separator())

        // 设置与 Finder 入口占位（票 19 接 SMAppService / 工作区打开）
        menu.addItem(disabled("登录时启动"))
        menu.addItem(disabled("打开快照文件夹"))
        menu.addItem(disabled("打开日志文件夹"))
        menu.addItem(.separator())

        // 能力状态行占位（spec §8.5，票 19 接启动探针）
        menu.addItem(disabled("能力状态（占位）"))
        menu.addItem(.separator())

        // 退出：骨架期唯一活项
        let quit = NSMenuItem(
            title: "退出窗口布局恢复器",
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
