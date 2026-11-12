import AppKit

// 未就绪菜单沿用完整菜单结构；只有设置与退出可用，不接保存/恢复回调。

public enum PlaceholderMenu {
    /// 状态项菜单不显示标题，仅作标识
    static let title = "Winductor"

    /// 构建 §6.1 骨架的占位菜单
    public static func build(onOpenSettings: (() -> Void)? = nil) -> NSMenu {
        WiredMenuBuilder.build(WiredMenuContent(
            statusLineTitle: "状态行（占位）", canSavePreset: false, restorePresets: [], canUndo: false,
            capabilityTitle: "能力状态（占位）",
            onSavePreset: nil, onRestorePreset: nil, onUndo: {}, onManagePresets: nil,
            onOpenSettings: onOpenSettings))
    }
}
