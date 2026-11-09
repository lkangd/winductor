import Core
import Foundation

// PresetManagerState.swift — 主窗口拓扑列表与拓扑页的呈现状态（display-presets 票 07 起；ui-refactor spec §5.2/§5.4）。纯函数，无 IO。
// 输入：PresetStore.topologies() + 当前观测拓扑 + 保存/覆盖可用性 + 视图选择（选中拓扑、排列图点选的屏）。
// 输出：
//   entries —— 侧栏拓扑列表（MainWindowState 据此分「当前排列 / 其他排列」）：当前拓扑置顶（尚无预设也按实况屏幕列出），其他按最近保存时间倒序；
//     标题别名优先，否则屏名组合（同名合并「×N」）；镜像中无当前拓扑（§3.3）。
//   selected —— 选中拓扑的排列图数据（当前拓扑用实况屏幕，其他用存储的展示数据 §3.2）与预设块；
//     恢复/覆盖仅当前拓扑且可用（未就绪 / 恢复进行中禁用）；改名、删除、设自动任何拓扑都可。
//     拓扑页（ui-refactor 票 04，spec §5.4）：标题区说明、「保存当前布局…」（仅当前拓扑）、预设块摘要与 Space 不足提示、
//     `⋯` 菜单（用当前布局覆盖… / 改名… / ─ / 删除…）。
//   selectedDisplayUUID / expandedPresetID —— 预设详情（display-presets 票 08）的筛选与展开接缝。

/// 侧栏的一个拓扑
public struct TopologyListEntry: Equatable, Identifiable {
    public var id: String { key }
    public let key: String
    /// 别名优先，否则屏名组合（如「内置 + DELL U2723QE ×2」）
    public let title: String
    /// 当前拓扑（侧栏「当前排列」）；false = 「其他排列」
    public let isCurrent: Bool
    /// 屏数（主窗口侧栏图标：单屏 / 多屏，ui-refactor 票 03）
    public let displayCount: Int
    /// 预设数（关于页统计，ui-refactor 票 03）
    public let presetCount: Int
}

/// 预设块 `⋯` 菜单的动作（ui-refactor 票 04）
public enum PresetRowAction: Equatable {
    case overwrite, rename, delete
}

/// 预设块 `⋯` 菜单的一项（原生菜单按此顺序构建）
public enum PresetRowMenuItem: Equatable {
    case action(PresetRowAction, title: String, isEnabled: Bool)
    case separator
}

/// 预设列表的一行（拓扑页的一个预设块）
public struct PresetRowState: Equatable, Identifiable {
    public let id: String
    public let name: String
    public let isAuto: Bool
    /// 该拓扑最近一次恢复所用的预设（spec §4.4）
    public let isLastRestored: Bool
    /// 「恢复」可用：仅当前拓扑且可用
    public let canRestore: Bool
    /// 「用当前布局覆盖」可用：仅当前拓扑且可用
    public let canOverwrite: Bool
    /// 摘要「{保存时间} 保存 · N 块屏幕 · N 个应用 · N 个窗口」（保存时间 yyyy-MM-dd HH:mm 本地时区；计数见 PresetSummary.totals）
    public let summaryText: String
    /// Space 不足提示（spec §5.3 文案，与恢复提示同源；仅当前拓扑且读得到实时 Space）
    public let spaceShortageTexts: [String]

    /// `⋯` 菜单：用当前布局覆盖…（仅当前拓扑且可用，否则置灰）/ 改名… / ─ / 删除…
    public var menuItems: [PresetRowMenuItem] {
        [.action(.overwrite, title: "用当前布局覆盖…", isEnabled: canOverwrite),
         .action(.rename, title: "改名…", isEnabled: true),
         .separator,
         .action(.delete, title: "删除…", isEnabled: true)]
    }
}

/// 拓扑页：选中拓扑
public struct SelectedTopologyState: Equatable {
    public let key: String
    public let title: String
    /// 标题区说明：「当前连接的屏幕排列 · N 块屏幕」/「未连接 · N 块屏幕 · 可以查看、改名、删除，不能恢复或覆盖」
    public let subtitle: String
    public let isCurrent: Bool
    /// 「保存当前布局…」显示：仅当前拓扑（尚无预设也显示）
    public let showsSavePreset: Bool
    /// 「保存当前布局…」可用：当前拓扑且可用（未就绪 / 恢复进行中置灰）
    public let canSavePreset: Bool
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
                            currentSpaces: [SpaceEntry]? = nil,
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
                                     isCurrent: key == currentKey,
                                     displayCount: displays.count,
                                     presetCount: record?.presets.count ?? 0)
        }

        let resolvedKey = selectedKey.flatMap { key in entries.contains { $0.key == key } ? key : nil }
            ?? currentKey ?? entries.first?.key
        let dateFormatter = PresetDateFormat.savedAt.formatter(timeZone: timeZone)
        let selected = resolvedKey.map { key -> SelectedTopologyState in
            let record = records[key]
            let isCurrent = key == currentKey
            let canApply = isCurrent && availability == .available
            let displays = isCurrent ? current.displays : record?.displays ?? []
            return SelectedTopologyState(
                key: key,
                title: entries.first { $0.key == key }?.title ?? "",
                subtitle: isCurrent ? "当前连接的屏幕排列 · \(displays.count) 块屏幕"
                    : "未连接 · \(displays.count) 块屏幕 · 可以查看、改名、删除，不能恢复或覆盖",
                isCurrent: isCurrent,
                showsSavePreset: isCurrent,
                canSavePreset: canApply,
                canEditAlias: record != nil,
                displays: displays,
                rows: (record?.presets ?? []).map { preset in
                    let savedAt = dateFormatter.string(from: preset.savedAt)
                    // Space 不足只对当前拓扑有意义（实时 Space 属于当前连接的屏）
                    let shortages = isCurrent
                        ? PresetSummary.spaceShortages(of: preset.snapshot, displays: displays,
                                                       currentSpaces: currentSpaces).map(\.text)
                        : []
                    return PresetRowState(id: preset.id, name: preset.name,
                                          isAuto: preset.isAuto,
                                          isLastRestored: preset.id == record?.lastRestoredPresetID,
                                          canRestore: canApply, canOverwrite: canApply,
                                          summaryText: "\(savedAt) 保存 · \(PresetSummary.totals(of: preset.snapshot).text)",
                                          spaceShortageTexts: shortages)
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

    private static func latestSave(_ topology: PresetTopology) -> Date {
        topology.presets.map(\.savedAt).max() ?? .distantPast
    }
}
