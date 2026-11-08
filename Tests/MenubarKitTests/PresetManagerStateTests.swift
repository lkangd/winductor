import Core
import Foundation
import XCTest
@testable import MenubarKit

// 票 07：预设管理窗口的呈现状态（display-presets spec §6.4）。
// 接缝：PresetManagerState.make(...) —— 存储内容 + 当前观测拓扑 + 可用性 → 左栏拓扑列表（排序/高亮/标题）、
// 选中拓扑的排列图数据与预设行（逐行操作可用性）。纯函数；存储用真实 PresetStore 写出输入。
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

    // MARK: 左栏

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

    /// 标题：别名优先；否则屏名组合（同名合并为「×N」，按排列从左到右）；副标题为屏数与预设数
    func testEntryTitlesPreferAliasElseGroupedScreenNames() throws {
        try save("工作", on: officeDesk)
        try save("家", on: homeDesk)
        try store.setAlias("公司", topologyKey: officeDesk.identity.key)

        let state = make(current: laptopOnly)
        let byKey = Dictionary(uniqueKeysWithValues: state.entries.map { ($0.key, $0) })

        XCTAssertEqual(byKey[officeDesk.identity.key]?.title, "公司")
        XCTAssertEqual(byKey[homeDesk.identity.key]?.title, "内置 + DELL U2723QE ×2")
        XCTAssertEqual(byKey[homeDesk.identity.key]?.subtitle, "3 屏 · 1 个预设")
    }

    /// 当前拓扑还没有任何预设：照样置顶（按实况屏幕），标「无预设」，别名不可改（尚无拓扑记录）
    func testCurrentTopologyWithoutPresetsIsListedFromLiveScreens() throws {
        try save("家", on: homeDesk)

        let state = make(current: officeDesk)

        let first = try XCTUnwrap(state.entries.first)
        XCTAssertEqual(first.key, officeDesk.identity.key)
        XCTAssertTrue(first.isCurrent)
        XCTAssertEqual(first.title, "内置 + LG HDR 4K")
        XCTAssertEqual(first.subtitle, "2 屏 · 无预设")
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
        XCTAssertEqual(rows.map(\.savedAtText), ["2026-11-08 14:30", "2026-11-08 14:31"])
        XCTAssertEqual(rows.map(\.isAuto), [true, false])
        XCTAssertEqual(rows.map(\.isLastRestored), [true, false])
        XCTAssertEqual(rows.map(\.canRestore), [true, true])
        XCTAssertEqual(rows.map(\.canOverwrite), [true, true])
    }

    /// 非当前拓扑：可查看、改名、删除、设自动，但恢复/覆盖禁用（acceptance）
    func testRowsOfOtherTopologyDisableRestoreAndOverwrite() throws {
        try save("家", on: homeDesk)

        let selected = try XCTUnwrap(make(current: officeDesk, selectedKey: homeDesk.identity.key).selected)

        XCTAssertFalse(selected.isCurrent)
        XCTAssertTrue(selected.canEditAlias)
        XCTAssertEqual(selected.rows.map(\.canRestore), [false])
        XCTAssertEqual(selected.rows.map(\.canOverwrite), [false])
    }

    /// 当前拓扑但恢复进行中 / 未就绪：恢复与覆盖同样禁用
    func testRowsOfCurrentTopologyDisabledWhileUnavailable() throws {
        try save("工作", on: officeDesk)

        for availability in [LayoutCaptureAvailability.restoring, .notReady] {
            let rows = try XCTUnwrap(make(current: officeDesk, availability: availability).selected?.rows)
            XCTAssertEqual(rows.map(\.canRestore), [false], "\(availability)")
            XCTAssertEqual(rows.map(\.canOverwrite), [false], "\(availability)")
        }
    }

    /// 排列图数据：当前拓扑用实况屏幕（偏移随拖动更新），其他拓扑用存储的展示数据
    func testArrangementUsesLiveScreensForCurrentAndStoredDataForOthers() throws {
        try save("工作", on: officeDesk)
        let nudged = topology([("BUILTIN", "内置", 0, 200, 1512, 982), ("LG-1", "LG HDR 4K", 1512, -100, 2560, 1440)])

        XCTAssertEqual(make(current: nudged).selected?.displays.map(\.frame.y), [200, -100])
        XCTAssertEqual(make(current: laptopOnly, selectedKey: officeDesk.identity.key).selected?.displays.map(\.frame.y),
                       [0, 0])
    }

    /// 排列图点选的屏（详情筛选，票 08 用）：不属于选中拓扑时清除
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
                      selectedDisplayUUID: String? = nil) -> PresetManagerState {
        PresetManagerState.make(topologies: store.topologies(), current: current, availability: availability,
                                selectedKey: selectedKey, selectedDisplayUUID: selectedDisplayUUID,
                                timeZone: TimeZone(secondsFromGMT: 0)!)
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
