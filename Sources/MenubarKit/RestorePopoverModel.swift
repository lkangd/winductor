import Core
import Foundation
import RestoreEngine

// RestorePopoverModel.swift — 恢复提示（spec §6.2）与自动恢复告知（§6.3）的视图模型，纯值类型。
// 摘要与 Space 不足文案来自 Core/PresetSummary（与预设详情 display-presets 票 08 同源）；AppKit 呈现见 RestorePopoverView.swift。

/// 恢复提示里的一个预设选项（摘要与 Space 不足提示按预设预先算好，切换单选不再读实时状态）
public struct RestorePromptOption: Equatable {
    public let presetID: String
    public let name: String
    /// 各屏应用/窗口计数行（屏自左而右）
    public let summaryLines: [String]
    /// Space 不足提示行（§5.3；实时 Space 读不到时为空）
    public let shortageLines: [String]
}

/// 恢复提示内容（§6.2）
public struct RestorePromptContent: Equatable {
    public let topologyKey: String
    /// 拓扑名（别名优先，默认屏幕名组合）
    public let title: String
    /// 预设选项（保存时间升序，同 PresetTopology.presets）
    public let options: [RestorePromptOption]
    /// 当前单选（「恢复」按它执行）
    public var selectedPresetID: String

    public var selected: RestorePromptOption? {
        options.first { $0.presetID == selectedPresetID }
    }

    /// 仅一个预设时不出单选，直接显示其名称与摘要
    public var showsPicker: Bool { options.count > 1 }

    /// 由判定时刻的拓扑构造；拓扑无预设 → nil（不该弹）。
    /// 默认选中：最近恢复过的（仍存在时）→ 否则最近保存的。
    public static func make(topology: PresetTopology, currentSpaces: [SpaceEntry]?) -> RestorePromptContent? {
        guard let latest = topology.presets.last else { return nil }
        let options = topology.presets.map { preset in
            RestorePromptOption(
                presetID: preset.id, name: preset.name,
                summaryLines: PresetSummary.displays(of: preset.snapshot, displays: topology.displays).map(\.text),
                shortageLines: PresetSummary.spaceShortages(of: preset.snapshot, displays: topology.displays,
                                                            currentSpaces: currentSpaces).map(\.text))
        }
        let lastRestored = topology.presets.first { $0.id == topology.lastRestoredPresetID }
        return RestorePromptContent(topologyKey: topology.key,
                                    title: TopologyNaming.title(alias: topology.alias, displays: topology.displays),
                                    options: options,
                                    selectedPresetID: (lastRestored ?? latest).id)
    }
}

/// 自动恢复告知内容（§6.3）
public struct AutoRestoreNoticeContent: Equatable {
    public let topologyKey: String
    /// 「已按『X』恢复」/ 失败时「按『X』恢复失败」（spec §6.3 用『』）
    public let headline: String
    /// 计数（口径同完成通知）；失败时为原因
    public let detail: String
    /// 降级附注（另起一行、次要样式；与 detail 合起来即完成通知的计数段）；无降级或失败时 nil
    public var degradeNote: String? = nil
    /// 「撤销」按钮（失败 = 管线中止，无可撤销的恢复，不给）
    public let showsUndo: Bool
    /// 「改用其他预设…」（拓扑下还有其他预设时；打开恢复提示）
    public let showsSwitchPreset: Bool

    public static func make(_ outcome: AutoRestoredOutcome) -> AutoRestoreNoticeContent {
        let failed = outcome.notice.failureDetail
        return AutoRestoreNoticeContent(
            topologyKey: outcome.topologyKey,
            headline: failed == nil ? "已按『\(outcome.presetName)』恢复" : "按『\(outcome.presetName)』恢复失败",
            detail: failed ?? outcome.notice.tallyText,
            degradeNote: failed == nil ? outcome.notice.degradeNote : nil,
            showsUndo: failed == nil,
            showsSwitchPreset: outcome.hasOtherPresets)
    }
}

/// 锚定菜单栏图标的 popover 当前呈现（提示与告知同一锚点，同一时刻至多一个）
public enum RestorePopoverPresentation: Equatable {
    case hidden
    case prompt(RestorePromptContent)
    /// generation：每次弹告知 +1，自动消失只收起同一代的告知（期间被替换的不误收新内容）
    case notice(AutoRestoreNoticeContent, generation: Int)
}

/// 输入事件：触发链判定结果（经协调器转成内容）+ 用户操作 + 告知到期
public enum RestorePopoverEvent: Equatable {
    /// 判定要提示（§5.1），或告知里点了「改用其他预设…」
    case promptNeeded(RestorePromptContent)
    /// 自动恢复完成
    case autoRestored(AutoRestoreNoticeContent)
    /// 新拓扑无预设 / 镜像中 / 未就绪：收起
    case dismiss
    /// 提示里切换单选
    case select(presetID: String)
    case restoreTapped
    case ignoreTapped
    /// 告知里的「撤销」
    case undoTapped
    /// 告知里的「改用其他预设…」
    case switchPresetTapped
    /// 告知到期（数秒后自动消失）
    case noticeExpired(generation: Int)
}

/// 状态机产出的副作用（协调器执行）
public enum RestorePopoverEffect: Equatable {
    /// 恢复提示「恢复」→ 触发链 restorePresetAsync（与自动恢复同一管线）
    case restore(presetID: String, topologyKey: String)
    /// 告知「撤销」→ 现有撤销管线（含两段式）
    case undo
    /// 告知「改用其他预设…」→ 按该拓扑现存预设构造恢复提示，再以 promptNeeded 喂回
    case openPrompt(topologyKey: String)
    /// 新告知弹出：到点后以 noticeExpired(generation:) 喂回
    case scheduleNoticeExpiry(generation: Int)
}

/// 呈现状态机（§6.2/§6.3 的替换、收起规则）。只在主线程使用。
/// 「忽略后直到下次拓扑变化不再弹」由触发链保证：promptNeeded 只在拓扑变化后的判定产出，忽略只需收起。
public struct RestorePopoverState {
    public private(set) var presentation: RestorePopoverPresentation = .hidden
    private var generation = 0

    public init() {}

    @discardableResult
    public mutating func apply(_ event: RestorePopoverEvent) -> [RestorePopoverEffect] {
        switch (event, presentation) {
        case (.promptNeeded(let content), _):
            presentation = .prompt(content)
        case (.autoRestored(let content), _):
            generation += 1
            presentation = .notice(content, generation: generation)
            return [.scheduleNoticeExpiry(generation: generation)]
        case (.dismiss, _):
            presentation = .hidden
        case (.select(let id), .prompt(var content)) where content.options.contains(where: { $0.presetID == id }):
            content.selectedPresetID = id
            presentation = .prompt(content)
        case (.restoreTapped, .prompt(let content)):
            presentation = .hidden
            return [.restore(presetID: content.selectedPresetID, topologyKey: content.topologyKey)]
        case (.ignoreTapped, .prompt):
            presentation = .hidden
        case (.undoTapped, .notice(let content, _)) where content.showsUndo:
            presentation = .hidden
            return [.undo]
        case (.switchPresetTapped, .notice(let content, _)) where content.showsSwitchPreset:
            return [.openPrompt(topologyKey: content.topologyKey)]
        case (.noticeExpired(let expired), .notice(_, let current)) where expired == current:
            presentation = .hidden
        default:
            break  // 与当前呈现不符的操作（已收起 / 已被替换）不生效
        }
        return []
    }
}
