// StatusLineState.swift — 菜单状态行四态（display-presets spec §6.1，票 06；取代票 19 的现势快照三态）。
// 「N 屏 · M 个预设（自动：X）」／「N 屏 · M 个预设」／「N 屏 · 无预设」／「镜像中」——
// 按当前观测拓扑（屏数、镜像态）与该拓扑的预设记录判定。N、M 用阿拉伯数字。
// 未就绪态不经此处（占位骨架 + 引导，见 PlaceholderMenu / ScreenCaptureReconfirmGuide）。

public enum StatusLineState: Equatable {
    /// 当前拓扑有预设；autoPresetName = 自动预设名（无自动为 nil）
    case presets(displayCount: Int, count: Int, autoPresetName: String?)
    /// 当前拓扑无预设
    case noPresets(displayCount: Int)
    /// 任一屏处于镜像集合（spec §3.3：整体禁用）
    case mirrored

    /// 判定入口（菜单构建时调用；镜像优先于预设态）
    public static func state(displayCount: Int, isMirrored: Bool,
                             presetCount: Int, autoPresetName: String?) -> StatusLineState {
        if isMirrored { return .mirrored }
        guard presetCount > 0 else { return .noPresets(displayCount: displayCount) }
        return .presets(displayCount: displayCount, count: presetCount, autoPresetName: autoPresetName)
    }

    /// 菜单状态行标题（spec §6.1 逐字措辞）
    public var title: String {
        switch self {
        case .mirrored:
            return "镜像中"
        case .noPresets(let displays):
            return "\(displays) 屏 · 无预设"
        case .presets(let displays, let count, let autoName?):
            return "\(displays) 屏 · \(count) 个预设（自动：\(autoName)）"
        case .presets(let displays, let count, nil):
            return "\(displays) 屏 · \(count) 个预设"
        }
    }

    /// 静态便捷入口（判定 + 标题一步）
    public static func title(displayCount: Int, isMirrored: Bool,
                             presetCount: Int, autoPresetName: String?) -> String {
        state(displayCount: displayCount, isMirrored: isMirrored,
              presetCount: presetCount, autoPresetName: autoPresetName).title
    }
}
