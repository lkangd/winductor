import XCTest
@testable import Core

// PresetDetailTests — 预设详情三层树推导（display-presets spec §6.4「预设详情」）。
// 接缝：PresetDetail.make（输入快照 + 展示数据 + 屏筛选 + 是否当前拓扑 + 实时 Space 清单 + 应用名解析）。
final class PresetDetailTests: XCTestCase {
    private let left = "L-UUID"
    private let right = "R-UUID"

    private var displays: [TopologyDisplayInfo] {
        [display(left, "内置", x: -1000), display(right, "DELL", x: 0)]
    }

    private func display(_ uuid: String, _ name: String, x: Double) -> TopologyDisplayInfo {
        TopologyDisplayInfo(uuid: uuid, name: name, frame: SnapshotDisplayFrame(x: x, y: 0, w: 1000, h: 800),
                            pixelWidth: 2000, pixelHeight: 1600, rotation: 0)
    }

    private func window(_ bundleID: String, on uuid: String, space: Int = 1,
                        minimized: Bool = false) -> SnapshotWindow {
        SnapshotWindow(bundleID: bundleID, title: "t", siblingIndex: 0, displayUUID: uuid, spaceIndex: space,
                       x: 0, y: 0, w: 0.5, h: 0.5, minimized: minimized)
    }

    private func space(_ uuid: String, _ index: Int, fullscreen: String? = nil) -> SnapshotSpace {
        SnapshotSpace(displayUUID: uuid, index: index, kind: fullscreen == nil ? .user : .fullscreen,
                      fullscreenAppBundleID: fullscreen)
    }

    /// 快照（topology 故意按右、左顺序给出：详情须按屏幕自左而右排）
    private func snapshot(spaces: [SnapshotSpace], windows: [SnapshotWindow]) -> Snapshot {
        Snapshot(capturedAt: Date(timeIntervalSince1970: 0),
                 topology: [
                     TopologyDisplay(uuid: right, localizedName: "快照里的右屏名",
                                     frame: SnapshotDisplayFrame(x: 0, y: 0, w: 1000, h: 800), orientation: 0),
                     TopologyDisplay(uuid: left, localizedName: "快照里的左屏名",
                                     frame: SnapshotDisplayFrame(x: -1000, y: 0, w: 1000, h: 800), orientation: 0),
                 ],
                 spaces: spaces, windows: windows)
    }

    private let names: (String) -> String? = { bundleID in
        ["com.apple.Terminal": "终端", "com.apple.Safari": "Safari", "com.apple.Notes": "备忘录"][bundleID]
    }

    private func detail(_ snap: Snapshot, filter: String? = nil, isCurrent: Bool = false,
                        currentSpaces: [SpaceEntry]? = nil) -> PresetDetail {
        PresetDetail.make(snapshot: snap, displays: displays, displayFilter: filter,
                          isCurrentTopology: isCurrent, currentSpaces: currentSpaces, appName: names)
    }

    /// 人读化整棵树：屏 / 　Space / 　　应用行，便于对照 spec 文案整体断言
    private func outline(_ detail: PresetDetail) -> [String] {
        detail.displays.flatMap { display in
            [display.name] + display.spaces.flatMap { space in
                ["  " + space.title] + space.apps.map { "    " + $0.text }
            }
        }
    }

    // MARK: 三层树

    /// 多屏多 Space：屏自左而右、Space 按 index、Space 下按应用聚合窗口数
    func testTreeGroupsWindowsByDisplayThenSpaceThenApp() {
        let snap = snapshot(
            spaces: [space(right, 1), space(left, 2), space(left, 1)],
            windows: [
                window("com.apple.Terminal", on: left),
                window("com.apple.Terminal", on: left),
                window("com.apple.Notes", on: left, space: 2),
                window("com.apple.Safari", on: right),
            ])

        XCTAssertEqual(outline(detail(snap)), [
            "内置",
            "  桌面 1",
            "    终端（2 个窗口）",
            "  桌面 2",
            "    备忘录（1 个窗口）",
            "DELL",
            "  桌面 1",
            "    Safari（1 个窗口）",
        ])
    }

    /// 最小化窗口计入窗口数并注明；同应用跨 Space 各自计数，不合并
    func testMinimizedCountAndSameAppAcrossSpacesCountedPerSpace() {
        let snap = snapshot(
            spaces: [space(left, 1), space(left, 2)],
            windows: [
                window("com.apple.Terminal", on: left),
                window("com.apple.Terminal", on: left, minimized: true),
                window("com.apple.Terminal", on: left, minimized: true),
                window("com.apple.Terminal", on: left, space: 2),
            ])

        XCTAssertEqual(outline(detail(snap)), [
            "内置",
            "  桌面 1",
            "    终端（3 个窗口，其中 2 个最小化）",
            "  桌面 2",
            "    终端（1 个窗口）",
            "DELL",
        ])
    }

    /// 全屏 Space 标「全屏 · 应用名」、不占桌面序号；应用名解析不到回退 bundleID
    func testFullscreenSpaceTitledWithAppNameAndSkipsDesktopNumbering() {
        let snap = snapshot(
            spaces: [space(left, 1), space(left, 2, fullscreen: "com.apple.Safari"), space(left, 3),
                     space(right, 1, fullscreen: "com.example.Unknown")],
            windows: [window("com.apple.Notes", on: left, space: 3)])

        XCTAssertEqual(outline(detail(snap)), [
            "内置",
            "  桌面 1",
            "  全屏 · Safari",
            "  桌面 2",
            "    备忘录（1 个窗口）",
            "DELL",
            "  全屏 · com.example.Unknown",
        ])
    }

    // MARK: 排列图点屏筛选

    /// 点选某屏：只列该屏（Space 不足提示同样只留该屏）
    func testDisplayFilterKeepsOnlySelectedDisplay() {
        let snap = snapshot(
            spaces: [space(left, 1), space(left, 2), space(right, 1), space(right, 2)],
            windows: [window("com.apple.Terminal", on: left), window("com.apple.Safari", on: right)])
        let current = [SpaceEntry(spaceID: 1, displayUUID: left, index: 1, kind: SpaceKind.user),
                       SpaceEntry(spaceID: 2, displayUUID: right, index: 1, kind: SpaceKind.user)]

        let filtered = detail(snap, filter: right, isCurrent: true, currentSpaces: current)

        XCTAssertEqual(outline(filtered), ["DELL", "  桌面 1", "    Safari（1 个窗口）", "  桌面 2"])
        XCTAssertEqual(filtered.spaceShortages.map(\.text),
                       ["屏幕「DELL」当前 Space 比预设少 1 个，多出的窗口将合并"])
    }

    // MARK: Space 不足提示（§5.3，仅当前拓扑）

    /// 与恢复提示同源；非当前拓扑的实时 Space 与预设无关，不提示
    func testSpaceShortageOnlyForCurrentTopology() {
        let snap = snapshot(spaces: [space(left, 1), space(left, 2), space(left, 3), space(right, 1)], windows: [])
        let current = [SpaceEntry(spaceID: 1, displayUUID: left, index: 1, kind: SpaceKind.user),
                       SpaceEntry(spaceID: 2, displayUUID: right, index: 1, kind: SpaceKind.user)]

        XCTAssertEqual(detail(snap, isCurrent: true, currentSpaces: current).spaceShortages,
                       PresetSummary.spaceShortages(of: snap, displays: displays, currentSpaces: current))
        XCTAssertEqual(detail(snap, isCurrent: true, currentSpaces: current).spaceShortages.map(\.text),
                       ["屏幕「内置」当前 Space 比预设少 2 个，多出的窗口将合并"])
        XCTAssertEqual(detail(snap, isCurrent: false, currentSpaces: current).spaceShortages, [])
    }
}
