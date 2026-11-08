import XCTest
@testable import Core

// PresetSummaryTests — 预设摘要 / Space 不足 / 拓扑名推导（display-presets spec §5.3/§6.2/§3.2）。
// 接缝：PresetSummary、TopologyNaming 的公开纯函数（输入快照 + 展示数据 + 实时 Space 清单）。
final class PresetSummaryTests: XCTestCase {
    private let left = "L-UUID"
    private let right = "R-UUID"

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

    /// 快照（topology 故意按右、左顺序给出：摘要须按屏幕自左而右排）
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

    // MARK: 摘要（各屏应用/窗口计数）

    /// 每屏一行：应用数按 bundleID 去重、窗口数含最小化；全屏 Space 的应用计 1 应用 1 窗口；空屏「无窗口」
    func testDisplaySummaryCountsAppsAndWindowsPerDisplayLeftToRight() {
        let snap = snapshot(
            spaces: [space(left, 1), space(left, 2), space(left, 3, fullscreen: "com.apple.Safari"), space(right, 1)],
            windows: [
                window("com.apple.Terminal", on: left),
                window("com.apple.Terminal", on: left, space: 2),
                window("com.apple.Notes", on: left, minimized: true),
                window("com.apple.Safari", on: left),
            ])
        let summary = PresetSummary.displays(of: snap,
                                             displays: [display(left, "内置", x: -1000), display(right, "DELL", x: 0)])

        XCTAssertEqual(summary.map(\.text), [
            "内置：3 个应用 · 5 个窗口",
            "DELL：无窗口",
        ])
    }

    // MARK: Space 不足提示（§5.3）

    /// 只比用户桌面数：全屏 Space 由恢复重新进入全屏生成，不算缺；当前比预设多不提示
    func testSpaceShortageComparesUserSpacesPerDisplay() {
        let snap = snapshot(
            spaces: [space(left, 1), space(left, 2), space(left, 3), space(left, 4, fullscreen: "com.apple.Safari"),
                     space(right, 1)],
            windows: [window("com.apple.Terminal", on: left, space: 3)])
        let current = [
            SpaceEntry(spaceID: 10, displayUUID: left, index: 1, kind: SpaceKind.user),
            SpaceEntry(spaceID: 11, displayUUID: left, index: 2, kind: SpaceKind.fullscreen),
            SpaceEntry(spaceID: 20, displayUUID: right, index: 1, kind: SpaceKind.user),
            SpaceEntry(spaceID: 21, displayUUID: right, index: 2, kind: SpaceKind.user),
        ]
        let hints = PresetSummary.spaceShortages(of: snap, displays: [display(left, "内置", x: -1000),
                                                                      display(right, "DELL", x: 0)],
                                                 currentSpaces: current)

        XCTAssertEqual(hints.map(\.text), ["屏幕「内置」当前 Space 比预设少 2 个，多出的窗口将合并"])
        XCTAssertEqual(hints.first?.missingCount, 2)
    }

    /// 实时 Space 清单读不到（nil / 空）：不猜，不提示
    func testSpaceShortageSilentWhenLiveSpacesUnavailable() {
        let snap = snapshot(spaces: [space(left, 1), space(left, 2), space(right, 1)], windows: [])
        let displays = [display(left, "内置", x: -1000), display(right, "DELL", x: 0)]

        XCTAssertEqual(PresetSummary.spaceShortages(of: snap, displays: displays, currentSpaces: nil), [])
        XCTAssertEqual(PresetSummary.spaceShortages(of: snap, displays: displays, currentSpaces: []), [])
    }

    // MARK: 拓扑名（§3.2 别名优先，默认屏幕名组合）

    func testTopologyTitlePrefersAliasElseGroupsScreenNamesLeftToRight() {
        let displays = [display("c", "DELL U2723QE", x: 2000), display("a", "内置", x: -1000),
                        display("b", "DELL U2723QE", x: 0)]

        XCTAssertEqual(TopologyNaming.title(alias: nil, displays: displays), "内置 + DELL U2723QE ×2")
        XCTAssertEqual(TopologyNaming.title(alias: "家里", displays: displays), "家里")
        XCTAssertEqual(TopologyNaming.title(alias: nil, displays: []), "当前屏幕组合", "元数据损坏时无展示数据")
    }

    /// 同名屏在摘要里按自左而右加「#n」区分
    func testSameNamedDisplaysAreNumberedInSummary() {
        let snap = snapshot(spaces: [], windows: [window("com.apple.Terminal", on: right)])
        let summary = PresetSummary.displays(of: snap, displays: [display(left, "DELL", x: -1000),
                                                                  display(right, "DELL", x: 0)])

        XCTAssertEqual(summary.map(\.text), ["DELL #1：无窗口", "DELL #2：1 个应用 · 1 个窗口"])
    }
}
