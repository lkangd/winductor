import Foundation
import XCTest
@testable import MenubarKit

// ui-refactor 票 03：统一主窗口的侧栏与选中态推导（ui-refactor spec §5.1/§5.2/§5.5/§5.6）。
// 接缝：MainWindowState.make(entries:requested:isReady:) —— 拓扑列表（PresetManagerState.entries）+ 用户请求的页
// + 就绪态 → 侧栏分组（当前排列 / 其他排列 / 应用，空组不显示）、选中页、关于页统计行；
// GeneralPageState.make(...) —— 权限现状 + 菜单同源快照态 → 通用页状态点 / 说明 / 可用性。纯函数。
final class MainWindowStateTests: XCTestCase {
    private let office = TopologyListEntry(key: "office", title: "内置 + DELL U2723QE ×2", subtitle: "3 屏 · 2 个预设",
                                           isCurrent: true, displayCount: 3, presetCount: 2)
    private let home = TopologyListEntry(key: "home", title: "家里", subtitle: "2 屏 · 3 个预设",
                                         isCurrent: false, displayCount: 2, presetCount: 3)
    private let laptop = TopologyListEntry(key: "laptop", title: "内置视网膜显示器", subtitle: "1 屏 · 1 个预设",
                                           isCurrent: false, displayCount: 1, presetCount: 1)

    // MARK: 侧栏分组

    /// 三组：当前排列（当前拓扑一项）/ 其他排列（其余，按给定顺序）/ 应用（通用、关于）
    func testSidebarGroupsCurrentOthersAndApp() {
        let state = MainWindowState.make(entries: [office, home, laptop], requested: nil, isReady: true)

        XCTAssertEqual(state.sections.map(\.kind), [.current, .others, .app])
        XCTAssertEqual(state.sections.map(\.title), ["当前排列", "其他排列", "应用"])
        XCTAssertEqual(state.sections[0].rows.map(\.page), [.topology("office")])
        XCTAssertEqual(state.sections[1].rows.map(\.page), [.topology("home"), .topology("laptop")])
        XCTAssertEqual(state.sections[2].rows.map(\.page), [.general, .about])
        XCTAssertEqual(state.sections[2].rows.map(\.title), ["通用", "关于"])
    }

    /// 没有其他拓扑：「其他排列」组不显示
    func testOthersGroupHiddenWhenEmpty() {
        let state = MainWindowState.make(entries: [office], requested: nil, isReady: true)

        XCTAssertEqual(state.sections.map(\.kind), [.current, .app])
    }

    /// 无当前拓扑（镜像中 / 无屏）：「当前排列」组不显示；全无拓扑时只剩「应用」
    func testCurrentGroupHiddenWithoutCurrentTopology() {
        let mirrored = MainWindowState.make(entries: [home], requested: nil, isReady: true)
        XCTAssertEqual(mirrored.sections.map(\.kind), [.others, .app])

        let none = MainWindowState.make(entries: [], requested: nil, isReady: true)
        XCTAssertEqual(none.sections.map(\.kind), [.app])
    }

    /// 行：标题 = 拓扑标题（别名优先，PresetManagerState 已推导）；图标 单屏 macbook / 多屏 rectangle.on.rectangle；
    /// 通用 gearshape、关于 info.circle（线条风格）
    func testRowTitlesAndSymbols() {
        let state = MainWindowState.make(entries: [office, laptop], requested: nil, isReady: true)
        let rows = state.sections.flatMap(\.rows)

        XCTAssertEqual(rows.map(\.title), ["内置 + DELL U2723QE ×2", "内置视网膜显示器", "通用", "关于"])
        XCTAssertEqual(rows.map(\.symbolName), ["rectangle.on.rectangle", "macbook", "gearshape", "info.circle"])
    }

    // MARK: 选中

    /// 默认选中当前拓扑
    func testDefaultSelectionIsCurrentTopology() {
        let state = MainWindowState.make(entries: [home, office, laptop].sorted { $0.isCurrent && !$1.isCurrent },
                                         requested: nil, isReady: true)

        XCTAssertEqual(state.selection, .topology("office"))
    }

    /// 无当前拓扑：落在第一项拓扑；全无拓扑：落在通用
    func testDefaultSelectionFallsBack() {
        XCTAssertEqual(MainWindowState.make(entries: [home, laptop], requested: nil, isReady: true).selection,
                       .topology("home"))
        XCTAssertEqual(MainWindowState.make(entries: [], requested: nil, isReady: true).selection, .general)
    }

    /// 请求页：通用/关于总有效；拓扑页仅当该拓扑仍在列表中，否则回落当前拓扑
    func testRequestedPageIsHonouredWhileValid() {
        let entries = [office, home]
        XCTAssertEqual(MainWindowState.make(entries: entries, requested: .about, isReady: true).selection, .about)
        XCTAssertEqual(MainWindowState.make(entries: entries, requested: .general, isReady: true).selection, .general)
        XCTAssertEqual(MainWindowState.make(entries: entries, requested: .topology("home"), isReady: true).selection,
                       .topology("home"))
        XCTAssertEqual(MainWindowState.make(entries: entries, requested: .topology("gone"), isReady: true).selection,
                       .topology("office"), "拓扑消失回落当前拓扑")
    }

    // MARK: 状态点

    /// 未就绪：通用项行尾状态点；就绪不显示；其他行恒无
    func testNotReadyShowsStatusDotOnGeneralOnly() {
        let notReady = MainWindowState.make(entries: [office, home], requested: nil, isReady: false)
        let dotted = notReady.sections.flatMap(\.rows).filter(\.showsStatusDot).map(\.page)
        XCTAssertEqual(dotted, [.general])

        let ready = MainWindowState.make(entries: [office, home], requested: nil, isReady: true)
        XCTAssertTrue(ready.sections.flatMap(\.rows).allSatisfy { !$0.showsStatusDot })
    }

    // MARK: 关于页统计

    /// 「N 个屏幕排列 · M 个预设」：N = 侧栏拓扑数，M = 预设总数
    func testAboutStatsText() {
        XCTAssertEqual(MainWindowState.make(entries: [office, home, laptop], requested: nil, isReady: true).aboutStatsText,
                       "3 个屏幕排列 · 6 个预设")
        XCTAssertEqual(MainWindowState.make(entries: [], requested: nil, isReady: true).aboutStatsText,
                       "0 个屏幕排列 · 0 个预设")
    }

    // MARK: 通用页

    /// 状态点逐项跟权限现状：屏幕录制重确认中也算未授权；说明随就绪态切换
    func testGeneralPagePermissionDotsAndCaption() {
        let ready = GeneralPageState.make(status: status(ax: true, sc: true), loginLaunchChecked: true, canUndo: false,
                                          presetsFolder: folder("presets"), logsFolder: folder("logs"))
        XCTAssertTrue(ready.accessibilityGranted)
        XCTAssertTrue(ready.screenCaptureGranted)
        XCTAssertEqual(ready.permissionCaption, GeneralPageState.readyCaption)
        XCTAssertTrue(ready.loginLaunchChecked)
        XCTAssertFalse(ready.canUndo)

        let missing = GeneralPageState.make(status: status(ax: true, sc: false), loginLaunchChecked: false, canUndo: true,
                                            presetsFolder: folder("presets"), logsFolder: folder("logs"))
        XCTAssertTrue(missing.accessibilityGranted)
        XCTAssertFalse(missing.screenCaptureGranted)
        XCTAssertEqual(missing.permissionCaption, GeneralPageState.notReadyCaption)
        XCTAssertTrue(missing.canUndo)

        let reconfirm = GeneralPageState.make(status: status(ax: true, sc: true, reconfirm: true),
                                              loginLaunchChecked: false, canUndo: false,
                                              presetsFolder: folder("presets"), logsFolder: folder("logs"))
        XCTAssertFalse(reconfirm.screenCaptureGranted, "重确认中：屏幕录制按未授权显示")
        XCTAssertEqual(reconfirm.permissionCaption, GeneralPageState.notReadyCaption)
    }

    /// 数据说明：两目录同在一个父目录 → 合并说父目录（家目录缩写为 ~）
    func testGeneralPageDataCaptionAbbreviatesHome() {
        let state = GeneralPageState.make(status: status(ax: true, sc: true), loginLaunchChecked: false, canUndo: false,
                                          presetsFolder: folder("presets"), logsFolder: folder("logs"))
        XCTAssertEqual(state.dataCaption, "预设与日志保存在 ~/Library/Application Support/Winductor。")

        let split = GeneralPageState.make(status: status(ax: true, sc: true), loginLaunchChecked: false, canUndo: false,
                                          presetsFolder: URL(fileURLWithPath: "/tmp/a/presets"),
                                          logsFolder: URL(fileURLWithPath: "/tmp/b/logs"))
        XCTAssertEqual(split.dataCaption, "预设保存在 /tmp/a/presets，日志保存在 /tmp/b/logs。")
    }

    // MARK: 辅助

    private func status(ax: Bool, sc: Bool, reconfirm: Bool = false) -> PermissionMonitor.Status {
        PermissionMonitor.Status(accessibilityGranted: ax, screenCaptureGranted: sc, screenCaptureNeedsReconfirm: reconfirm)
    }

    private func folder(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Winductor/\(name)", isDirectory: true)
    }
}
