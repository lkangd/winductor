import Core
import Foundation
import XCTest
@testable import MenubarKit

// display-presets 票 07 起：主窗口拓扑列表与拓扑页的呈现状态（ui-refactor spec §5.2/§5.4）。
// 接缝：PresetManagerState.make(...) —— 存储内容 + 当前观测拓扑 + 可用性 → 侧栏拓扑列表（排序/当前/标题）、
// 选中拓扑的排列图数据与预设块（逐块操作可用性）。纯函数；存储用真实 PresetStore 写出输入。
final class PresetManagerStateTests: XCTestCase {
    private var directory: URL!
    private var store: PresetStore!
    private var clock: Date!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("winductor-managerstate-\(UUID().uuidString)", isDirectory: true)
        clock = Date(timeIntervalSince1970: 1_794_148_200)  // 2026-11-08 14:30:00 UTC
        store = PresetStore(directory: directory, now: { [unowned self] in clock })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 侧栏拓扑列表

    /// 当前拓扑置顶高亮；其他拓扑灰显，按最近保存时间倒序
    func testCurrentTopologyFirstThenOthersByMostRecentSave() throws {
        try save("旧", on: laptopOnly)
        try save("家", on: homeDesk)
        try save("工作", on: officeDesk)
        try save("家 2", on: homeDesk)  // 家里拓扑最近一次保存最新

        let state = make(current: officeDesk)

        XCTAssertEqual(state.entries.map(\.key), [officeDesk.identity.key, homeDesk.identity.key,
                                                  laptopOnly.identity.key])
        XCTAssertEqual(state.entries.map(\.isCurrent), [true, false, false])
    }

    /// 标题：别名优先；否则屏名组合（同名合并为「×N」，按排列从左到右）；另带屏数与预设数
    func testEntryTitlesPreferAliasElseGroupedScreenNames() throws {
        try save("工作", on: officeDesk)
        try save("家", on: homeDesk)
        try store.setAlias("公司", topologyKey: officeDesk.identity.key)

        let state = make(current: laptopOnly)
        let byKey = Dictionary(uniqueKeysWithValues: state.entries.map { ($0.key, $0) })

        XCTAssertEqual(byKey[officeDesk.identity.key]?.title, "公司")
        XCTAssertEqual(byKey[homeDesk.identity.key]?.title, "内置 + DELL U2723QE ×2")
        // 主窗口侧栏图标（单屏/多屏）与关于页统计用的计数（ui-refactor 票 03）
        XCTAssertEqual(byKey[homeDesk.identity.key]?.displayCount, 3)
        XCTAssertEqual(byKey[homeDesk.identity.key]?.presetCount, 1)
    }

    /// 当前拓扑还没有任何预设：照样置顶（按实况屏幕），预设数 0，别名不可改（尚无拓扑记录）
    func testCurrentTopologyWithoutPresetsIsListedFromLiveScreens() throws {
        try save("家", on: homeDesk)

        let state = make(current: officeDesk)

        let first = try XCTUnwrap(state.entries.first)
        XCTAssertEqual(first.key, officeDesk.identity.key)
        XCTAssertTrue(first.isCurrent)
        XCTAssertEqual(first.title, "内置 + LG HDR 4K")
        XCTAssertEqual(first.displayCount, 2)
        XCTAssertEqual(first.presetCount, 0)
        XCTAssertEqual(state.selected?.key, officeDesk.identity.key)
        XCTAssertEqual(state.selected?.canEditAlias, false)
        XCTAssertEqual(state.selected?.rows, [])
    }

    /// 镜像中：无当前拓扑（spec §3.3），全部灰显
    func testMirroringHasNoCurrentTopology() throws {
        try save("家", on: homeDesk)

        let state = make(current: mirrored)

        XCTAssertEqual(state.entries.map(\.key), [homeDesk.identity.key])
        XCTAssertEqual(state.entries.map(\.isCurrent), [false])
    }

    // MARK: 选中拓扑

    /// 默认选中当前拓扑；选中的拓扑消失时回落到当前拓扑；无当前拓扑时回落到首项
    func testSelectionDefaultsToCurrentAndFallsBack() throws {
        try save("家", on: homeDesk)
        try save("工作", on: officeDesk)

        XCTAssertEqual(make(current: officeDesk).selectedKey, officeDesk.identity.key)
        XCTAssertEqual(make(current: officeDesk, selectedKey: homeDesk.identity.key).selectedKey, homeDesk.identity.key)
        XCTAssertEqual(make(current: officeDesk, selectedKey: "gone").selectedKey, officeDesk.identity.key)
        XCTAssertEqual(make(current: mirrored, selectedKey: "gone").selectedKey, make(current: mirrored).entries.first?.key)
    }

    /// 预设行：名称、保存时间、自动、最近恢复；恢复/覆盖仅当前拓扑可用
    func testRowsOfCurrentTopologyAllowRestoreAndOverwrite() throws {
        let work = try save("工作", on: officeDesk)  // 首个预设默认自动；save 之后时钟前进 1 分钟
        try save("会议", on: officeDesk)
        try store.recordRestored(presetID: work.id, topologyKey: officeDesk.identity.key)

        let rows = try XCTUnwrap(make(current: officeDesk).selected?.rows)

        XCTAssertEqual(rows.map(\.name), ["工作", "会议"])
        XCTAssertEqual(rows.map { String($0.summaryText.prefix(19)) }, ["2026-11-08 14:30 保存", "2026-11-08 14:31 保存"])
        XCTAssertEqual(rows.map(\.isAuto), [true, false])
        XCTAssertEqual(rows.map(\.isLastRestored), [true, false])
        XCTAssertEqual(rows.map(\.canRestore), [true, true])
        XCTAssertEqual(rows.map(\.canOverwrite), [true, true])
        XCTAssertEqual(rows.first?.menuItems, menu(overwriteEnabled: true))
    }

    /// 非当前拓扑：可查看、改名、删除、设自动，但恢复/覆盖禁用（acceptance）；
    /// `⋯` 菜单里「用当前布局覆盖…」置灰，改名/删除照常（ui-refactor 票 04）
    func testRowsOfOtherTopologyDisableRestoreAndOverwrite() throws {
        try save("家", on: homeDesk)

        let selected = try XCTUnwrap(make(current: officeDesk, selectedKey: homeDesk.identity.key).selected)

        XCTAssertFalse(selected.isCurrent)
        XCTAssertTrue(selected.canEditAlias)
        XCTAssertEqual(selected.rows.map(\.canRestore), [false])
        XCTAssertEqual(selected.rows.map(\.canOverwrite), [false])
        XCTAssertEqual(selected.rows.first?.menuItems, menu(overwriteEnabled: false))
    }

    /// 当前拓扑但恢复进行中 / 未就绪：恢复与覆盖同样禁用（`⋯` 菜单覆盖项置灰）
    func testRowsOfCurrentTopologyDisabledWhileUnavailable() throws {
        try save("工作", on: officeDesk)

        for availability in [LayoutCaptureAvailability.restoring, .notReady] {
            let rows = try XCTUnwrap(make(current: officeDesk, availability: availability).selected?.rows)
            XCTAssertEqual(rows.map(\.canRestore), [false], "\(availability)")
            XCTAssertEqual(rows.map(\.canOverwrite), [false], "\(availability)")
            XCTAssertEqual(rows.first?.menuItems, menu(overwriteEnabled: false), "\(availability)")
        }
    }

    // MARK: 拓扑页（ui-refactor 票 04，spec §5.4）

    /// 标题区说明：当前「当前连接的屏幕排列 · N 块屏幕」/ 非当前「未连接 · N 块屏幕 · …」
    func testSubtitleDistinguishesCurrentFromOtherTopology() throws {
        try save("家", on: homeDesk)

        XCTAssertEqual(make(current: officeDesk).selected?.subtitle, "当前连接的屏幕排列 · 2 块屏幕")
        XCTAssertEqual(make(current: officeDesk, selectedKey: homeDesk.identity.key).selected?.subtitle,
                       "未连接 · 3 块屏幕 · 可以查看、改名、删除，不能恢复或覆盖")
    }

    /// 预设分区空态说明：当前拓扑引导保存；非当前「无预设」；有预设时无说明
    func testEmptyPresetsCaptionDistinguishesCurrentFromOther() throws {
        let home = try save("家", on: homeDesk)
        try store.deletePreset(id: home.id, topologyKey: homeDesk.identity.key)  // 拓扑记录还在、预设清空

        XCTAssertEqual(make(current: officeDesk).selected?.emptyPresetsText,
                       "还没有预设。点「保存当前布局…」把现在的窗口布局存为预设。")
        XCTAssertEqual(make(current: officeDesk, selectedKey: homeDesk.identity.key).selected?.emptyPresetsText, "无预设")
        try save("工作", on: officeDesk)
        XCTAssertNil(make(current: officeDesk).selected?.emptyPresetsText)
    }

    /// 笔形改名按钮的悬停说明：可改「改名称」；当前拓扑尚未保存过预设（无拓扑记录）时「保存过预设后才能改名称」
    func testEditAliasHelpFollowsAvailability() throws {
        try save("家", on: homeDesk)

        XCTAssertEqual(make(current: officeDesk).selected?.editAliasHelp, "保存过预设后才能改名称")
        XCTAssertEqual(make(current: officeDesk, selectedKey: homeDesk.identity.key).selected?.editAliasHelp, "改名称")
    }

    /// 排列图屏幕块的悬停说明随点选切换；预设块详情按钮随展开切换；分区末尾说明与无拓扑空态逐字
    func testTopologyPageCopy() throws {
        let preset = try save("工作", on: officeDesk)

        let plain = make(current: officeDesk)
        XCTAssertEqual(plain.displayTileHelp(uuid: "LG-1"), "只看这块屏幕的详情")
        XCTAssertEqual(make(current: officeDesk, selectedDisplayUUID: "LG-1").displayTileHelp(uuid: "LG-1"),
                       "再次点击显示全部屏幕")
        XCTAssertEqual(plain.detailToggleTitle(presetID: preset.id), "显示详情")
        let expanded = PresetManagerState.make(topologies: store.topologies(), current: officeDesk,
                                               availability: .available, selectedKey: nil,
                                               expandedPresetID: preset.id)
        XCTAssertEqual(expanded.detailToggleTitle(presetID: preset.id), "收起详情")
        XCTAssertEqual(SelectedTopologyState.autoRestoreNote,
                       "勾选「自动恢复」的预设会在屏幕排列切换到这里时直接恢复，不再询问；每个屏幕排列至多一个。")
        XCTAssertEqual(PresetManagerState.noTopologyText, "还没有保存过任何预设")
    }

    /// 「保存当前布局…」：仅当前拓扑显示（尚无预设也显示）；恢复进行中 / 未就绪置灰
    func testSavePresetButtonOnlyOnCurrentTopology() throws {
        try save("家", on: homeDesk)

        let current = try XCTUnwrap(make(current: officeDesk).selected)
        XCTAssertEqual([current.showsSavePreset, current.canSavePreset], [true, true])
        let busy = try XCTUnwrap(make(current: officeDesk, availability: .restoring).selected)
        XCTAssertEqual([busy.showsSavePreset, busy.canSavePreset], [true, false])
        let other = try XCTUnwrap(make(current: officeDesk, selectedKey: homeDesk.identity.key).selected)
        XCTAssertEqual([other.showsSavePreset, other.canSavePreset], [false, false])
    }

    /// 预设块摘要「{保存时间}保存 · N 块屏幕 · N 个应用 · N 个窗口」（计数见 PresetSummary.totals）
    func testRowSummaryCombinesSavedAtAndTotals() throws {
        let snap = Snapshot(
            capturedAt: clock,
            topology: [TopologyDisplay(uuid: "BUILTIN", localizedName: "内置",
                                       frame: SnapshotDisplayFrame(x: 0, y: 0, w: 1512, h: 982), orientation: 0),
                       TopologyDisplay(uuid: "LG-1", localizedName: "LG HDR 4K",
                                       frame: SnapshotDisplayFrame(x: 1512, y: 0, w: 2560, h: 1440), orientation: 0)],
            spaces: [SnapshotSpace(displayUUID: "BUILTIN", index: 1, kind: .user, fullscreenAppBundleID: nil),
                     SnapshotSpace(displayUUID: "LG-1", index: 2, kind: .fullscreen, fullscreenAppBundleID: "com.apple.Keynote")],
            windows: [window("com.apple.Terminal", on: "BUILTIN"), window("com.apple.Terminal", on: "BUILTIN"),
                      window("com.apple.Safari", on: "BUILTIN")])
        try store.addPreset(name: "工作", snapshot: snap, topology: officeDesk)

        XCTAssertEqual(make(current: officeDesk).selected?.rows.map(\.summaryText),
                       ["2026-11-08 14:30 保存 · 2 块屏幕 · 3 个应用 · 4 个窗口"])
    }

    /// Space 不足提示挂在预设块上（不必展开详情）：仅当前拓扑、按实时 Space 对比；读不到实时 Space 不提示
    func testRowSpaceShortagesOnlyOnCurrentTopology() throws {
        let snap = Snapshot(
            capturedAt: clock,
            topology: [TopologyDisplay(uuid: "LG-1", localizedName: "LG HDR 4K",
                                       frame: SnapshotDisplayFrame(x: 1512, y: 0, w: 2560, h: 1440), orientation: 0)],
            spaces: [SnapshotSpace(displayUUID: "LG-1", index: 1, kind: .user, fullscreenAppBundleID: nil),
                     SnapshotSpace(displayUUID: "LG-1", index: 2, kind: .user, fullscreenAppBundleID: nil)],
            windows: [])
        try store.addPreset(name: "工作", snapshot: snap, topology: officeDesk)
        let live = [SpaceEntry(spaceID: 1, displayUUID: "LG-1", index: 1, kind: SpaceKind.user)]

        XCTAssertEqual(make(current: officeDesk, currentSpaces: live).selected?.rows.map(\.spaceShortageTexts),
                       [["屏幕「LG HDR 4K」当前 Space 比预设少 1 个，多出的窗口将合并"]])
        XCTAssertEqual(make(current: officeDesk).selected?.rows.map(\.spaceShortageTexts), [[]])
        XCTAssertEqual(make(current: laptopOnly, selectedKey: officeDesk.identity.key, currentSpaces: live)
            .selected?.rows.map(\.spaceShortageTexts), [[]])
    }

    /// 排列图数据：当前拓扑用实况屏幕（偏移随拖动更新），其他拓扑用存储的展示数据
    func testArrangementUsesLiveScreensForCurrentAndStoredDataForOthers() throws {
        try save("工作", on: officeDesk)
        let nudged = topology([("BUILTIN", "内置", 0, 200, 1512, 982), ("LG-1", "LG HDR 4K", 1512, -100, 2560, 1440)])

        XCTAssertEqual(make(current: nudged).selected?.displays.map(\.frame.y), [200, -100])
        XCTAssertEqual(make(current: laptopOnly, selectedKey: officeDesk.identity.key).selected?.displays.map(\.frame.y),
                       [0, 0])
    }

    /// 排列图点选的屏（详情筛选，display-presets 票 08 用）：不属于选中拓扑时清除
    func testSelectedDisplayClearedWhenNotInSelectedTopology() throws {
        try save("工作", on: officeDesk)

        XCTAssertEqual(make(current: officeDesk, selectedDisplayUUID: "LG-1").selectedDisplayUUID, "LG-1")
        XCTAssertNil(make(current: officeDesk, selectedDisplayUUID: "DELL-2").selectedDisplayUUID)
    }

    // MARK: 工具

    @discardableResult
    private func save(_ name: String, on topology: ObservedTopology) throws -> Preset {
        defer { clock = clock.addingTimeInterval(60) }
        return try store.addPreset(name: name, snapshot: Snapshot(capturedAt: clock, topology: [], spaces: [], windows: []),
                                   topology: topology)
    }

    private func make(current: ObservedTopology,
                      availability: LayoutCaptureAvailability = .available,
                      selectedKey: String? = nil,
                      selectedDisplayUUID: String? = nil,
                      currentSpaces: [SpaceEntry]? = nil) -> PresetManagerState {
        PresetManagerState.make(topologies: store.topologies(), current: current, availability: availability,
                                selectedKey: selectedKey, selectedDisplayUUID: selectedDisplayUUID,
                                currentSpaces: currentSpaces,
                                timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    /// `⋯` 菜单：用当前布局覆盖…（仅当前拓扑且可用）/ 改名… / ─ / 删除…
    private func menu(overwriteEnabled: Bool) -> [PresetRowMenuItem] {
        [.action(.overwrite, title: "用当前布局覆盖…", isEnabled: overwriteEnabled),
         .action(.rename, title: "改名…", isEnabled: true),
         .separator,
         .action(.delete, title: "删除…", isEnabled: true)]
    }

    private func window(_ bundleID: String, on uuid: String) -> SnapshotWindow {
        SnapshotWindow(bundleID: bundleID, title: "t", siblingIndex: 0, displayUUID: uuid, spaceIndex: 1,
                       x: 0, y: 0, w: 0.5, h: 0.5, minimized: false)
    }

    private func topology(_ screens: [(String, String, Double, Double, Double, Double)],
                          mirrored: Bool = false) -> ObservedTopology {
        ObservedTopology(screens: screens.map { uuid, name, x, y, w, h in
            TopologyScreen(uuid: uuid, name: name, frame: CGRect(x: x, y: y, width: w, height: h),
                           pixelWidth: Int(w) * 2, pixelHeight: Int(h) * 2, rotation: 0, isMirrored: mirrored)
        })
    }

    private var laptopOnly: ObservedTopology { topology([("BUILTIN", "内置", 0, 0, 1512, 982)]) }

    private var officeDesk: ObservedTopology {
        topology([("BUILTIN", "内置", 0, 0, 1512, 982), ("LG-1", "LG HDR 4K", 1512, 0, 2560, 1440)])
    }

    private var homeDesk: ObservedTopology {
        topology([("BUILTIN", "内置", 0, 0, 1512, 982), ("DELL-1", "DELL U2723QE", 1512, 0, 2560, 1440),
                  ("DELL-2", "DELL U2723QE", 4072, 0, 2560, 1440)])
    }

    private var mirrored: ObservedTopology {
        topology([("BUILTIN", "内置", 0, 0, 1512, 982), ("LG-1", "LG HDR 4K", 0, 0, 1512, 982)], mirrored: true)
    }
}
