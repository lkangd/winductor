import Foundation

// PresetDetail.swift — 预设详情「屏幕 → Space → 应用」三层树推导（display-presets spec §6.4「预设详情」）。
// 纯函数，管理窗口（票 08）展开预设行时渲染；屏顺序与命名与恢复提示同源（TopologyNaming.orderedDisplays）。
// 口径：
//   - Space 按 index 升序；用户桌面按该屏用户桌面的序数称「桌面 N」（与调度中心一致，全屏 Space 不占号）
//   - Space 下按 bundleID 聚合窗口：窗口数含最小化窗口，另注「其中 N 个最小化」
//   - 快照未记录的 spaceIndex（理论上不出现）仍按其 index 列出，窗口不丢

/// Space 下的一个应用
public struct PresetDetailApp: Equatable, Sendable {
    public let bundleID: String
    public let name: String
    /// 窗口数（含最小化）
    public let windowCount: Int
    public let minimizedCount: Int

    /// 「终端（2 个窗口）」/「终端（3 个窗口，其中 2 个最小化）」
    public var text: String {
        let minimized = minimizedCount > 0 ? "，其中 \(minimizedCount) 个最小化" : ""
        return "\(name)（\(windowCount) 个窗口\(minimized)）"
    }
}

/// 屏下的一个 Space
public struct PresetDetailSpace: Equatable, Sendable {
    public let index: Int
    public let isFullscreen: Bool
    /// 「桌面 1」/「全屏 · Safari」
    public let title: String
    public let apps: [PresetDetailApp]
}

/// 一块屏
public struct PresetDetailDisplay: Equatable, Sendable {
    public let uuid: String
    public let name: String
    public let spaces: [PresetDetailSpace]
}

public struct PresetDetail: Equatable, Sendable {
    /// 屏自左而右
    public let displays: [PresetDetailDisplay]
    /// Space 不足提示（§5.3，与恢复提示同源 PresetSummary.spaceShortages）；仅当前拓扑，随屏筛选
    public let spaceShortages: [SpaceShortage]

    /// - Parameters:
    ///   - displays: 拓扑展示数据（屏名）
    ///   - displayFilter: 排列图点选的屏 UUID（nil = 全部屏）
    ///   - isCurrentTopology: 预设所属拓扑是否当前拓扑（Space 不足提示仅当前拓扑）
    ///   - currentSpaces: 实时受管 Space 清单（nil = 读不到，不提示）
    ///   - appName: bundleID → 应用名（nil = 解析不到，回退 bundleID）
    public static func make(snapshot: Snapshot, displays: [TopologyDisplayInfo], displayFilter: String?,
                            isCurrentTopology: Bool, currentSpaces: [SpaceEntry]?,
                            appName: (String) -> String?) -> PresetDetail {
        let shown: (String) -> Bool = { uuid in displayFilter == nil || displayFilter == uuid }
        let tree = TopologyNaming.orderedDisplays(of: snapshot, displays: displays)
            .filter { shown($0.uuid) }
            .map { uuid, name in
                PresetDetailDisplay(uuid: uuid, name: name,
                                    spaces: spaces(on: uuid, of: snapshot, appName: appName))
            }
        let shortages = isCurrentTopology
            ? PresetSummary.spaceShortages(of: snapshot, displays: displays, currentSpaces: currentSpaces)
                .filter { shown($0.displayUUID) }
            : []
        return PresetDetail(displays: tree, spaceShortages: shortages)
    }

    private static func spaces(on uuid: String, of snapshot: Snapshot,
                               appName: (String) -> String?) -> [PresetDetailSpace] {
        let windows = snapshot.windows.filter { $0.displayUUID == uuid }
        let indices = Set(snapshot.spaces.filter { $0.displayUUID == uuid }.map(\.index))
            .union(windows.map(\.spaceIndex)).sorted()
        var desktopOrdinal = 0
        return indices.map { index in
            let recorded = snapshot.spaces.first { $0.displayUUID == uuid && $0.index == index }
            let title: String
            let isFullscreen = recorded?.kind == .fullscreen
            if isFullscreen {
                // 全屏应用由 Space 携带、不进 windows（§7.3）；缺 bundleID 时只标「全屏」
                title = recorded?.fullscreenAppBundleID.map { "全屏 · \(appName($0) ?? $0)" } ?? "全屏"
            } else {
                desktopOrdinal += 1
                title = "桌面 \(desktopOrdinal)"
            }
            let inSpace = windows.filter { $0.spaceIndex == index }
            // 应用按快照中首次出现的顺序
            var order: [String] = []
            for window in inSpace where !order.contains(window.bundleID) { order.append(window.bundleID) }
            let apps = order.map { bundleID in
                let own = inSpace.filter { $0.bundleID == bundleID }
                return PresetDetailApp(bundleID: bundleID, name: appName(bundleID) ?? bundleID,
                                       windowCount: own.count, minimizedCount: own.filter(\.minimized).count)
            }
            return PresetDetailSpace(index: index, isFullscreen: isFullscreen, title: title, apps: apps)
        }
    }
}
