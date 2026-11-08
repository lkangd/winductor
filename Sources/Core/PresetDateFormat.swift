import Foundation

// PresetDateFormat.swift — 预设相关时间文本的单一定义（display-presets 评审修复：原先各处各写一份格式串）。
// 默认预设名：菜单「保存当前布局为预设…」输入框与 DebugCLI snapshot-now；保存时间：管理窗口与 DebugCLI list-presets。

public enum PresetDateFormat: String {
    /// 默认预设名「11-08 14:30」（spec §4.3）
    case defaultName = "MM-dd HH:mm"
    /// 保存时间「2026-11-08 14:30」
    case savedAt = "yyyy-MM-dd HH:mm"

    /// 固定 en_US_POSIX（格式串不随系统区域设置变形）
    public func formatter(timeZone: TimeZone = .current) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = rawValue
        return formatter
    }
}
