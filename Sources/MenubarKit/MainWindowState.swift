import Foundation

// MainWindowState.swift — 统一主窗口的呈现状态（ui-refactor 票 03，spec §5.2/§5.5/§5.6）。纯函数，无 IO。
// 输入：拓扑列表（PresetManagerState.entries：当前拓扑置顶、其余按最近保存倒序，标题已推导）+ 用户请求的页 + 就绪态。
// 输出：
//   sections —— 侧栏分组：当前排列（当前拓扑一项）/ 其他排列（其余拓扑）/ 应用（通用、关于）；拓扑组为空则整组不显示；
//     行图标单屏 macbook、多屏 rectangle.on.rectangle、通用 gearshape、关于 info.circle（线条风格）；未就绪时通用行尾状态点。
//   selection —— 请求页有效则用之（通用/关于总有效；拓扑页仅当该拓扑仍在列表中），否则当前拓扑 → 第一项拓扑 → 通用。
//     拓扑页内容的选中拓扑仍由 PresetManagerModel 管（同一回落口径），本层只决定侧栏高亮与内容区显示哪一页。
//   aboutStatsText —— 关于页「N 个屏幕排列 · M 个预设」（与侧栏同源）。
// GeneralPageState：通用页的权限状态点 / 说明 / 菜单同源快照态（登录时启动勾选、撤销可用性）与数据目录说明。

/// 主窗口的页
public enum MainWindowPage: Hashable {
    /// 某个屏幕排列（拓扑键）
    case topology(String)
    case general
    case about
}

/// 侧栏一行
public struct SidebarRow: Equatable, Identifiable {
    public var id: MainWindowPage { page }
    public let page: MainWindowPage
    /// 行文字（过长尾部截断，悬停显示全名）
    public let title: String
    /// SF Symbol 名（单色，统一装进 16×16 框）
    public let symbolName: String
    /// 行尾黄色状态点（通用项在未就绪时）
    public let showsStatusDot: Bool
}

/// 侧栏一组
public struct SidebarSection: Equatable, Identifiable {
    public enum Kind: Hashable {
        case current
        case others
        case app
    }

    public var id: Kind { kind }
    public let kind: Kind
    /// 组名（11pt semibold 次要色）
    public let title: String
    public let rows: [SidebarRow]
}

public struct MainWindowState: Equatable {
    public let sections: [SidebarSection]
    public let selection: MainWindowPage
    /// 关于页统计行「N 个屏幕排列 · M 个预设」
    public let aboutStatsText: String

    public static let empty = make(entries: [], requested: nil, isReady: true)

    /// - Parameters:
    ///   - entries: PresetManagerState.entries（当前拓扑至多一项且置顶）
    ///   - requested: 用户最近点选的页（nil = 默认：当前拓扑）
    ///   - isReady: 权限就绪（PermissionMonitor.Status.isReady）；未就绪时通用项带状态点
    public static func make(entries: [TopologyListEntry], requested: MainWindowPage?, isReady: Bool) -> MainWindowState {
        func row(_ entry: TopologyListEntry) -> SidebarRow {
            SidebarRow(page: .topology(entry.key), title: entry.title,
                       symbolName: entry.displayCount == 1 ? "macbook" : "rectangle.on.rectangle",
                       showsStatusDot: false)
        }
        let current = entries.filter(\.isCurrent).map(row)
        let others = entries.filter { !$0.isCurrent }.map(row)
        var sections: [SidebarSection] = []
        if !current.isEmpty { sections.append(SidebarSection(kind: .current, title: "当前排列", rows: current)) }
        if !others.isEmpty { sections.append(SidebarSection(kind: .others, title: "其他排列", rows: others)) }
        sections.append(SidebarSection(kind: .app, title: "应用", rows: [
            SidebarRow(page: .general, title: "通用", symbolName: "gearshape", showsStatusDot: !isReady),
            SidebarRow(page: .about, title: "关于", symbolName: "info.circle", showsStatusDot: false),
        ]))

        let selection: MainWindowPage
        switch requested {
        case .general?, .about?:
            selection = requested!
        case .topology(let key)? where entries.contains(where: { $0.key == key }):
            selection = .topology(key)
        default:
            let fallback = entries.first(where: \.isCurrent) ?? entries.first
            selection = fallback.map { .topology($0.key) } ?? .general
        }

        let presetCount = entries.reduce(0) { $0 + $1.presetCount }
        return MainWindowState(sections: sections, selection: selection,
                               aboutStatsText: "\(entries.count) 个屏幕排列 · \(presetCount) 个预设")
    }
}

/// 通用页（spec §5.5）：系统 / 恢复 / 数据三分区的状态
public struct GeneralPageState: Equatable {
    /// 辅助功能状态点（绿 = 已授权，黄 = 未授权）
    public let accessibilityGranted: Bool
    /// 屏幕与系统录音状态点（重确认中按未授权）
    public let screenCaptureGranted: Bool
    /// 系统分区权限行的说明（随就绪态切换）
    public let permissionCaption: String
    /// 「登录时启动」勾选态（菜单同源）
    public let loginLaunchChecked: Bool
    /// 「撤销」可用（菜单同源；不可撤销时置灰）
    public let canUndo: Bool
    /// 数据分区说明（目录路径，家目录缩写为 ~）
    public let dataCaption: String

    static let readyCaption = "两项权限已就绪。Winductor 只在本机读取和移动窗口，不上传任何数据。"
    static let notReadyCaption = "缺少权限时无法保存或恢复布局。打开授权引导按步骤开启。"

    public static func make(status: PermissionMonitor.Status, loginLaunchChecked: Bool, canUndo: Bool,
                            presetsFolder: URL, logsFolder: URL) -> GeneralPageState {
        GeneralPageState(accessibilityGranted: status.accessibilityGranted,
                         screenCaptureGranted: status.screenCaptureEffectivelyGranted,
                         permissionCaption: status.isReady ? readyCaption : notReadyCaption,
                         loginLaunchChecked: loginLaunchChecked,
                         canUndo: canUndo,
                         dataCaption: dataCaption(presetsFolder: presetsFolder, logsFolder: logsFolder))
    }

    private static func dataCaption(presetsFolder: URL, logsFolder: URL) -> String {
        func display(_ url: URL) -> String { (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath }
        let presetsParent = presetsFolder.standardizedFileURL.deletingLastPathComponent()
        if presetsParent == logsFolder.standardizedFileURL.deletingLastPathComponent() {
            return "预设与日志保存在 \(display(presetsParent))。"
        }
        return "预设保存在 \(display(presetsFolder))，日志保存在 \(display(logsFolder))。"
    }
}
