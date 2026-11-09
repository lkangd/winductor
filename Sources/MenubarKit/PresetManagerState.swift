import Core
import Foundation

// PresetManagerState.swift — 预设管理窗口的呈现状态（display-presets 票 07，spec §6.4）。纯函数，无 IO。
// 输入：PresetStore.topologies() + 当前观测拓扑 + 保存/覆盖可用性 + 视图选择（选中拓扑、排列图点选的屏）。
// 输出：
//   左栏 entries —— 当前拓扑置顶高亮（尚无预设也按实况屏幕列出），其他拓扑灰显、按最近保存时间倒序；
//     标题别名优先，否则屏名组合（同名合并「×N」）；镜像中无当前拓扑（§3.3）。
//   selected —— 选中拓扑的排列图数据（当前拓扑用实况屏幕，其他用存储的展示数据 §3.2）与预设行；
//     行内恢复/覆盖仅当前拓扑且可用（未就绪 / 恢复进行中禁用）；「覆盖」按钮仅当前拓扑显示；改名、删除、设自动任何拓扑都可。
//   selectedDisplayUUID / expandedPresetID —— 预设详情（display-presets 票 08）的筛选与展开接缝。

/// 左栏的一个拓扑
public struct TopologyListEntry: Equatable, Identifiable {
    public var id: String { key }
    public let key: String
    /// 别名优先，否则屏名组合（如「内置 + DELL U2723QE ×2」）
    public let title: String
    /// 「3 屏 · 2 个预设」/「3 屏 · 无预设」
    public let subtitle: String
    /// 当前拓扑（置顶高亮）；false = 灰显
    public let isCurrent: Bool
}

/// 预设列表的一行
public struct PresetRowState: Equatable, Identifiable {
    public let id: String
    public let name: String
    /// 保存时间（yyyy-MM-dd HH:mm，本地时区）
    public let savedAtText: String
    public let isAuto: Bool
    /// 该拓扑最近一次恢复所用的预设（spec §4.4）
    public let isLastRestored: Bool
    /// 「恢复」可用：仅当前拓扑且可用
    public let canRestore: Bool
    /// 「用当前布局覆盖」可用：仅当前拓扑且可用
    public let canOverwrite: Bool
    /// 行内显式「覆盖」按钮是否显示：仅当前拓扑（非当前拓扑不显示而非置灰；不可用时置灰见 canOverwrite，display-presets 票 13）
    public let showsOverwrite: Bool
}

/// 右侧：选中拓扑
public struct SelectedTopologyState: Equatable {
    public let key: String
    public let title: String
    public let isCurrent: Bool
    /// 别名可改（拓扑已有存储记录；当前拓扑尚未保存过任何预设时不可改）
    public let canEditAlias: Bool
    /// 排列图数据
    public let displays: [TopologyDisplayInfo]
    public let rows: [PresetRowState]
}

public struct PresetManagerState: Equatable {
    public let entries: [TopologyListEntry]
    public let selectedKey: String?
    public let selected: SelectedTopologyState?
    /// 排列图点选的屏（nil = 全部屏；display-presets 票 08 预设详情据此只显示该屏）
    public let selectedDisplayUUID: String?
    /// 展开详情的预设（display-presets 票 08）
    public let expandedPresetID: String?

    public static let empty = PresetManagerState(entries: [], selectedKey: nil, selected: nil,
                                                 selectedDisplayUUID: nil, expandedPresetID: nil)

    public static func make(topologies: [PresetTopology],
                            current: ObservedTopology,
                            availability: LayoutCaptureAvailability,
                            selectedKey: String?,
                            selectedDisplayUUID: String? = nil,
                            expandedPresetID: String? = nil,
                            timeZone: TimeZone = .current) -> PresetManagerState {
        let currentKey = current.isMirrored || current.displays.isEmpty ? nil : current.identity.key
        let records = Dictionary(topologies.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        // 当前拓扑置顶（尚无记录则按实况合成），其余按最近保存倒序、同时刻按标题
        var listed: [(key: String, record: PresetTopology?)] = topologies
            .filter { $0.key != currentKey }
            .sorted { lhs, rhs in
                let (l, r) = (latestSave(lhs), latestSave(rhs))
                return l != r ? l > r : title(of: lhs, displays: lhs.displays) < title(of: rhs, displays: rhs.displays)
            }
            .map { ($0.key, $0) }
        if let currentKey { listed.insert((currentKey, records[currentKey]), at: 0) }

        let entries = listed.map { key, record in
            let displays = key == currentKey ? current.displays : record?.displays ?? []
            return TopologyListEntry(key: key,
                                     title: title(of: record, displays: displays),
                                     subtitle: subtitle(displayCount: displays.count, presetCount: record?.presets.count ?? 0),
                                     isCurrent: key == currentKey)
        }

        let resolvedKey = selectedKey.flatMap { key in entries.contains { $0.key == key } ? key : nil }
            ?? currentKey ?? entries.first?.key
        let dateFormatter = PresetDateFormat.savedAt.formatter(timeZone: timeZone)
        let selected = resolvedKey.map { key -> SelectedTopologyState in
            let record = records[key]
            let isCurrent = key == currentKey
            let canApply = isCurrent && availability == .available
            return SelectedTopologyState(
                key: key,
                title: entries.first { $0.key == key }?.title ?? "",
                isCurrent: isCurrent,
                canEditAlias: record != nil,
                displays: isCurrent ? current.displays : record?.displays ?? [],
                rows: (record?.presets ?? []).map { preset in
                    PresetRowState(id: preset.id, name: preset.name,
                                   savedAtText: dateFormatter.string(from: preset.savedAt),
                                   isAuto: preset.isAuto,
                                   isLastRestored: preset.id == record?.lastRestoredPresetID,
                                   canRestore: canApply, canOverwrite: canApply,
                                   showsOverwrite: isCurrent)
                })
        }
        let displayUUID = selectedDisplayUUID.flatMap { uuid in
            selected?.displays.contains { $0.uuid == uuid } == true ? uuid : nil
        }
        let expanded = expandedPresetID.flatMap { id in selected?.rows.contains { $0.id == id } == true ? id : nil }
        return PresetManagerState(entries: entries, selectedKey: resolvedKey, selected: selected,
                                  selectedDisplayUUID: displayUUID, expandedPresetID: expanded)
    }

    /// 默认标题：屏名按排列顺序，同名合并「×N」（首次出现的位置）
    static func defaultTitle(for displays: [TopologyDisplayInfo]) -> String {
        var names: [String] = []
        var counts: [String: Int] = [:]
        for display in displays {
            if counts[display.name] == nil { names.append(display.name) }
            counts[display.name, default: 0] += 1
        }
        guard !names.isEmpty else { return "未知屏幕组合" }
        return names.map { counts[$0, default: 1] > 1 ? "\($0) ×\(counts[$0, default: 1])" : $0 }
            .joined(separator: " + ")
    }

    private static func title(of record: PresetTopology?, displays: [TopologyDisplayInfo]) -> String {
        record?.alias ?? defaultTitle(for: displays)
    }

    private static func subtitle(displayCount: Int, presetCount: Int) -> String {
        let presets = presetCount == 0 ? "无预设" : "\(presetCount) 个预设"
        // 元数据损坏时无展示数据：只报预设数
        return displayCount == 0 ? presets : "\(displayCount) 屏 · \(presets)"
    }

    private static func latestSave(_ topology: PresetTopology) -> Date {
        topology.presets.map(\.savedAt).max() ?? .distantPast
    }
}
