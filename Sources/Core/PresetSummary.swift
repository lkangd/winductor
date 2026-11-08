import Foundation

// PresetSummary.swift — 从预设快照推导的人读摘要（display-presets spec §6.2 恢复提示摘要、§5.3 Space 不足提示）。
// 纯函数，恢复提示（票 05）与预设详情（票 08）共用同一推导与文案。
// 口径：
//   - 屏顺序 = 快照 topology 按 frame 自左而右（同 x 自上而下），与排列直觉一致
//   - 屏名 = 拓扑展示数据（TopologyDisplayInfo.name）优先，缺失回退快照 localizedName；同名屏按顺序加「#n」区分
//   - 应用数按 bundleID 去重；窗口数含最小化窗口；全屏 Space 的应用计 1 个应用、1 个窗口（快照 schema
//     不把全屏应用放进 windows，§7.3）

/// 单屏摘要（恢复提示「各屏应用/窗口计数」）
public struct PresetDisplaySummary: Equatable, Sendable {
    public let displayUUID: String
    public let displayName: String
    public let appCount: Int
    public let windowCount: Int

    /// 「DELL：3 个应用 · 7 个窗口」/「DELL：无窗口」
    public var text: String {
        guard windowCount > 0 else { return "\(displayName)：无窗口" }
        return "\(displayName)：\(appCount) 个应用 · \(windowCount) 个窗口"
    }
}

public enum PresetSummary {
    /// 各屏应用/窗口计数（屏自左而右）
    public static func displays(of snapshot: Snapshot, displays: [TopologyDisplayInfo]) -> [PresetDisplaySummary] {
        TopologyNaming.orderedDisplays(of: snapshot, displays: displays).map { uuid, name in
            let windows = snapshot.windows.filter { $0.displayUUID == uuid }
            let fullscreenApps = snapshot.spaces
                .filter { $0.displayUUID == uuid && $0.kind == .fullscreen }
                .compactMap(\.fullscreenAppBundleID)
            let apps = Set(windows.map(\.bundleID)).union(fullscreenApps)
            return PresetDisplaySummary(displayUUID: uuid, displayName: name,
                                        appCount: apps.count, windowCount: windows.count + fullscreenApps.count)
        }
    }
}

/// 单屏 Space 不足（spec §5.3：预设多出的 Space 上的窗口按 index 就近并入，不补建）
public struct SpaceShortage: Equatable, Sendable {
    public let displayUUID: String
    public let displayName: String
    /// 当前比预设少的用户桌面数（> 0）
    public let missingCount: Int

    /// §5.3 文案（恢复提示与预设详情同源）
    public var text: String {
        "屏幕「\(displayName)」当前 Space 比预设少 \(missingCount) 个，多出的窗口将合并"
    }
}

extension PresetSummary {
    /// 各屏 Space 不足提示（屏自左而右）。只比用户桌面数：全屏 Space 由恢复重新进入全屏时生成，不算缺。
    /// currentSpaces = 实时受管 Space 清单；nil / 空 = 本轮读不到，不猜、不提示。
    public static func spaceShortages(of snapshot: Snapshot, displays: [TopologyDisplayInfo],
                                      currentSpaces: [SpaceEntry]?) -> [SpaceShortage] {
        guard let currentSpaces, !currentSpaces.isEmpty else { return [] }
        return TopologyNaming.orderedDisplays(of: snapshot, displays: displays).compactMap { uuid, name in
            let wanted = snapshot.spaces.filter { $0.displayUUID == uuid && $0.kind == .user }.count
            let present = currentSpaces.filter { $0.displayUUID == uuid && $0.kind == SpaceKind.user }.count
            guard wanted > present else { return nil }
            return SpaceShortage(displayUUID: uuid, displayName: name, missingCount: wanted - present)
        }
    }
}

/// 拓扑与屏的人读命名（spec §3.2：别名优先，默认屏幕名组合）
public enum TopologyNaming {
    /// 拓扑名：别名优先；否则屏幕名自左而右，同名合并为「名 ×n」（「内置 + DELL U2723QE ×2」）
    public static func title(alias: String?, displays: [TopologyDisplayInfo]) -> String {
        if let alias, !alias.isEmpty { return alias }
        let names = displays.sorted { ($0.frame.x, $0.frame.y) < ($1.frame.x, $1.frame.y) }.map(\.name)
        guard !names.isEmpty else { return "当前屏幕组合" }
        var groups: [(name: String, count: Int)] = []
        for name in names {
            if let index = groups.firstIndex(where: { $0.name == name }) {
                groups[index].count += 1
            } else {
                groups.append((name, 1))
            }
        }
        return groups.map { $0.count > 1 ? "\($0.name) ×\($0.count)" : $0.name }.joined(separator: " + ")
    }

    /// 快照中的屏（自左而右）及其人读名（同名加「#n」）
    public static func orderedDisplays(of snapshot: Snapshot,
                                       displays: [TopologyDisplayInfo]) -> [(uuid: String, name: String)] {
        let ordered = snapshot.topology.sorted {
            ($0.frame.x, $0.frame.y) < ($1.frame.x, $1.frame.y)
        }
        let names = ordered.map { screen in
            displays.first { $0.uuid == screen.uuid }?.name ?? screen.localizedName
        }
        return zip(ordered, disambiguated(names)).map { ($0.uuid, $1) }
    }

    /// 同名屏按出现顺序加「#1」「#2」…；不重名的保持原样
    static func disambiguated(_ names: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return names.map { name in
            guard names.filter({ $0 == name }).count > 1 else { return name }
            seen[name, default: 0] += 1
            return "\(name) #\(seen[name]!)"
        }
    }
}
