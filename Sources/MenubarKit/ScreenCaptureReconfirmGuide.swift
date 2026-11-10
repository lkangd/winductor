import AppKit

// ScreenCaptureReconfirmGuide.swift — 屏幕录制重确认的菜单内被动引导（票 18，spec §8.4）。
// 收回/失效时降回未就绪：状态行「屏幕录制权限需重新确认」点击直达系统设置 + 固定说明文案，不弹窗。
// 文案为 §8.4 逐字引文（测试以独立字面量锁定）。

public enum ScreenCaptureReconfirmGuide {
    /// §8.4 状态行（点击直达系统设置的「录屏与系统录音」面板）
    public static let statusLineTitle = "屏幕录制权限需重新确认"
    /// §8.4 菜单内固定说明文案（逐字）
    public static let noticeText = "macOS 会定期要求重新确认屏幕录制权限。请在系统设置中重新打开开关，然后重启应用。"

    /// 构建重确认引导块：可点状态行 + 置灰说明行
    public static func menuItems(statusLineTarget: AnyObject?, action: Selector) -> [NSMenuItem] {
        let statusLine = NSMenuItem(title: statusLineTitle, action: action, keyEquivalent: "")
        statusLine.target = statusLineTarget
        statusLine.isEnabled = true

        let notice = NSMenuItem(title: noticeText, action: nil, keyEquivalent: "")
        notice.isEnabled = false
        return [statusLine, notice]
    }

    /// 拼进占位菜单：替换索引 0 的「状态行（占位）」，引导块插其后，其余结构不动
    public static func install(into menu: NSMenu, statusLineTarget: AnyObject?, action: Selector) {
        let items = menuItems(statusLineTarget: statusLineTarget, action: action)
        if let placeholderStatus = menu.items.first, placeholderStatus.title == "状态行（占位）" {
            menu.removeItem(placeholderStatus)
        }
        for (offset, item) in items.enumerated() {
            menu.insertItem(item, at: offset)
        }
    }
}
