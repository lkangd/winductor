import Core
import Foundation
import SnapshotEngine
import XCTest
@testable import MenubarKit

// display-presets 票 07：预设管理窗口的操作（display-presets spec §6.4 + §4.1/§4.2 规则在 UI 层的呈现）。
// 接缝：PresetManagerModel 公共接口（reload / select* / rename / delete / setAuto / editAlias / restore / overwrite）
// 与其 state。存储用真实 PresetStore（临时目录）；对话框经 PresetManagerDialogs（脚本假件）；
// 当前拓扑经注入闭包；恢复经注入闭包（生产 = MenuRestoreCoordinator.restorePreset）。
final class PresetManagerModelTests: XCTestCase {
    private final class ScriptedDialogs: PresetManagerDialogs, PresetOverwriteConfirming {
        var renameAnswers: [String?] = []
        var aliasAnswers: [String?] = []
        var deleteAnswers: [Bool] = []
        var overwriteAnswers: [Bool] = []
        private(set) var renamePrompts: [(current: String, message: String?)] = []
        private(set) var aliasPrompts: [(current: String?, placeholder: String)] = []
        private(set) var deletePrompts: [String] = []
        private(set) var errors: [String] = []

        func promptRename(currentName: String, message: String?) -> String? {
            renamePrompts.append((currentName, message))
            return renameAnswers.isEmpty ? nil : renameAnswers.removeFirst()
        }

        func promptAlias(currentAlias: String?, placeholder: String) -> String? {
            aliasPrompts.append((currentAlias, placeholder))
            return aliasAnswers.isEmpty ? nil : aliasAnswers.removeFirst()
        }

        func confirmDelete(presetName: String) -> Bool {
            deletePrompts.append(presetName)
            return deleteAnswers.isEmpty ? false : deleteAnswers.removeFirst()
        }

        func showError(_ message: String) { errors.append(message) }

        func confirmOverwrite(presetName: String) -> Bool {
            overwriteAnswers.isEmpty ? false : overwriteAnswers.removeFirst()
        }
    }

    private var directory: URL!
    private var store: PresetStore!
    private var clock: Date!
    private var dialogs: ScriptedDialogs!
    private var current: ObservedTopology!
    private var availability: LayoutCaptureAvailability = .available
    private var restored: [(id: String, key: String)] = []
    private var liveSpaces: [SpaceEntry]?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("winductor-managermodel-\(UUID().uuidString)", isDirectory: true)
        clock = Date(timeIntervalSince1970: 1_794_148_200)
        store = PresetStore(directory: directory, now: { [unowned self] in clock })
        dialogs = ScriptedDialogs()
        current = office
        availability = .available
        restored = []
        liveSpaces = nil
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 改名（spec §4.1：同拓扑唯一，撞名提示改名）

    func testRenameStoresNewName() throws {
        let work = try save("工作", on: office)
        let model = makeModel()

        model.rename(presetID: work.id)

        XCTAssertEqual(dialogs.renamePrompts.map(\.current), ["工作"])
        XCTAssertEqual(rowNames(model), ["工作"], "取消不改")

        dialogs.renameAnswers = ["办公室"]
        model.rename(presetID: work.id)
        XCTAssertEqual(rowNames(model), ["办公室"])
        XCTAssertEqual(store.topology(key: office.identity.key)?.presets.map(\.name), ["办公室"])
    }

    func testRenameToDuplicateRepromptsWithMessage() throws {
        let work = try save("工作", on: office)
        try save("家", on: office)
        dialogs.renameAnswers = ["家", "工作 B"]
        let model = makeModel()

        model.rename(presetID: work.id)

        XCTAssertEqual(dialogs.renamePrompts.map(\.message), [nil, "已有名为「家」的预设，请换一个名称"])
        XCTAssertEqual(dialogs.renamePrompts.map(\.current), ["工作", "家"], "重弹时预填刚输入的名称")
        XCTAssertEqual(rowNames(model), ["工作 B", "家"])
    }

    // MARK: 删除（带确认；删自动不转移，spec §4.2）

    func testDeleteRequiresConfirmationAndDoesNotTransferAuto() throws {
        let work = try save("工作", on: office)  // 首个预设默认自动
        try save("家", on: office)
        let model = makeModel()

        model.delete(presetID: work.id)
        XCTAssertEqual(dialogs.deletePrompts, ["工作"])
        XCTAssertEqual(rowNames(model), ["工作", "家"], "确认框取消不删")

        dialogs.deleteAnswers = [true]
        model.delete(presetID: work.id)
        XCTAssertEqual(rowNames(model), ["家"])
        XCTAssertEqual(model.state.selected?.rows.map(\.isAuto), [false], "删除自动预设后拓扑变为无自动")
    }

    // MARK: 自动开关（互斥，spec §4.2）

    func testSetAutoIsExclusiveWithinTopology() throws {
        try save("工作", on: office)
        let home = try save("家", on: office)
        let model = makeModel()

        model.setAuto(true, presetID: home.id)
        XCTAssertEqual(model.state.selected?.rows.map(\.isAuto), [false, true])

        model.setAuto(false, presetID: home.id)
        XCTAssertEqual(model.state.selected?.rows.map(\.isAuto), [false, false])
    }

    /// 非当前拓扑也可设自动、改名、删除（spec §6.4 左栏：灰显但可操作）
    func testOtherTopologyCanBeEditedButNotRestored() throws {
        let away = try save("出差", on: laptop)
        try save("会议", on: laptop)
        let model = makeModel()
        model.selectTopology(laptop.identity.key)

        model.setAuto(false, presetID: away.id)
        XCTAssertEqual(model.state.selected?.rows.map(\.isAuto), [false, false])

        model.restore(presetID: away.id)
        XCTAssertTrue(restored.isEmpty, "非当前拓扑不恢复")
    }

    // MARK: 别名（spec §3.2：空 = 回到默认屏名组合）

    func testEditAliasSetsAndClearsTitle() throws {
        try save("工作", on: office)
        dialogs.aliasAnswers = ["公司", "  "]
        let model = makeModel()

        model.editAlias()
        XCTAssertEqual(model.state.entries.first?.title, "公司")
        XCTAssertEqual(dialogs.aliasPrompts.first?.current, nil)
        XCTAssertEqual(dialogs.aliasPrompts.first?.placeholder, "内置 + LG HDR 4K")

        model.editAlias()
        XCTAssertEqual(dialogs.aliasPrompts.last?.current, "公司")
        XCTAssertEqual(model.state.entries.first?.title, "内置 + LG HDR 4K")
    }

    // MARK: 恢复 / 覆盖（仅当前拓扑）

    func testRestoreRoutesCurrentTopologyPreset() throws {
        let work = try save("工作", on: office)
        let model = makeModel()

        model.restore(presetID: work.id)

        XCTAssertEqual(restored.map(\.id), [work.id])
        XCTAssertEqual(restored.map(\.key), [office.identity.key])
    }

    func testOverwriteReplacesSnapshotAndRefreshesRow() throws {
        let work = try save("工作", on: office)
        clock = clock.addingTimeInterval(3600)
        dialogs.overwriteAnswers = [true]
        let model = makeModel(captureMarker: "new")

        model.overwrite(presetID: work.id)

        XCTAssertEqual(store.topology(key: office.identity.key)?.presets.first?.snapshot.spaces.first?.fullscreenAppBundleID,
                       "new")
        XCTAssertEqual(model.state.selected?.rows.map(\.savedAtText), ["2026-11-08 15:31"])
    }

    // MARK: 刷新与选择

    /// 拓扑实时切换：reload 后当前拓扑与选中项跟随实况
    func testReloadFollowsLiveTopologyChange() throws {
        try save("工作", on: office)
        try save("出差", on: laptop)
        let model = makeModel()
        XCTAssertEqual(model.state.selected?.key, office.identity.key)

        current = laptop
        model.reload()

        XCTAssertEqual(model.state.entries.map(\.isCurrent), [true, false])
        XCTAssertEqual(model.state.entries.first?.key, laptop.identity.key)
        XCTAssertEqual(model.state.selected?.key, laptop.identity.key, "未手动选择时跟随当前拓扑")
    }

    /// 手动选了别的拓扑后，拓扑变化不夺走选择
    func testManualSelectionSurvivesReload() throws {
        try save("工作", on: office)
        try save("出差", on: laptop)
        let model = makeModel()
        model.selectTopology(laptop.identity.key)

        model.reload()

        XCTAssertEqual(model.state.selected?.key, laptop.identity.key)
    }

    /// 排列图点选屏：再点同一块取消；切换拓扑清除
    func testSelectDisplayTogglesAndClearsOnTopologySwitch() throws {
        try save("工作", on: office)
        try save("出差", on: laptop)
        let model = makeModel()

        model.selectDisplay("LG-1")
        XCTAssertEqual(model.state.selectedDisplayUUID, "LG-1")
        model.selectDisplay("LG-1")
        XCTAssertNil(model.state.selectedDisplayUUID)

        model.selectDisplay("LG-1")
        model.selectTopology(laptop.identity.key)
        XCTAssertNil(model.state.selectedDisplayUUID)
    }

    /// display-presets 票 08 接缝：选中拓扑的存储记录（含快照）随选择切换；展开状态随行存在
    func testSelectedRecordAndExpansionFollowSelection() throws {
        let work = try save("工作", on: office)
        let away = try save("出差", on: laptop)
        let model = makeModel()
        XCTAssertEqual(model.selectedTopologyRecord?.presets.map(\.id), [work.id])

        model.toggleExpanded(presetID: work.id)
        XCTAssertEqual(model.state.expandedPresetID, work.id)
        model.selectTopology(laptop.identity.key)
        XCTAssertEqual(model.selectedTopologyRecord?.presets.map(\.id), [away.id])
        XCTAssertNil(model.state.expandedPresetID, "切换拓扑收起详情")
    }

    /// display-presets 票 08：展开行的预设详情（屏 → Space → 应用）随点屏筛选；Space 不足提示仅当前拓扑、按实时 Space 对比
    func testExpandedDetailFollowsDisplayFilterAndComparesLiveSpacesOnCurrentTopologyOnly() throws {
        let snap = Snapshot(
            capturedAt: clock,
            topology: [TopologyDisplay(uuid: "BUILTIN", localizedName: "内置",
                                       frame: SnapshotDisplayFrame(x: 0, y: 0, w: 1512, h: 982), orientation: 0),
                       TopologyDisplay(uuid: "LG-1", localizedName: "LG HDR 4K",
                                       frame: SnapshotDisplayFrame(x: 1512, y: 0, w: 1512, h: 982), orientation: 0)],
            spaces: [SnapshotSpace(displayUUID: "BUILTIN", index: 1, kind: .user, fullscreenAppBundleID: nil),
                     SnapshotSpace(displayUUID: "LG-1", index: 1, kind: .user, fullscreenAppBundleID: nil),
                     SnapshotSpace(displayUUID: "LG-1", index: 2, kind: .user, fullscreenAppBundleID: nil)],
            windows: [SnapshotWindow(bundleID: "com.apple.Terminal", title: "t", siblingIndex: 0, displayUUID: "LG-1",
                                     spaceIndex: 2, x: 0, y: 0, w: 0.5, h: 0.5, minimized: true)])
        let work = try store.addPreset(name: "工作", snapshot: snap, topology: office)
        try save("出差", on: laptop)
        liveSpaces = [SpaceEntry(spaceID: 1, displayUUID: "BUILTIN", index: 1, kind: SpaceKind.user),
                      SpaceEntry(spaceID: 2, displayUUID: "LG-1", index: 1, kind: SpaceKind.user)]
        let model = makeModel()
        XCTAssertNil(model.expandedDetail, "未展开不推导")

        model.toggleExpanded(presetID: work.id)
        XCTAssertEqual(model.expandedDetail?.displays.map(\.name), ["内置", "LG HDR 4K"])
        XCTAssertEqual(model.expandedDetail?.displays.last?.spaces.last?.apps.map(\.text),
                       ["终端（1 个窗口，其中 1 个最小化）"])
        XCTAssertEqual(model.expandedDetail?.spaceShortages.map(\.text),
                       ["屏幕「LG HDR 4K」当前 Space 比预设少 1 个，多出的窗口将合并"])

        model.selectDisplay("BUILTIN")
        XCTAssertEqual(model.expandedDetail?.displays.map(\.name), ["内置"])
        XCTAssertEqual(model.expandedDetail?.spaceShortages, [])

        current = laptop
        model.selectDisplay("BUILTIN")
        model.selectTopology(office.identity.key)
        model.toggleExpanded(presetID: work.id)
        XCTAssertEqual(model.expandedDetail?.displays.count, 2)
        XCTAssertEqual(model.expandedDetail?.spaceShortages, [], "非当前拓扑不提示")
    }

    /// 存储写失败（预设已被别处删除）：报错并刷新
    func testStoreErrorIsShownAndStateRefreshed() throws {
        let work = try save("工作", on: office)
        let model = makeModel()
        try store.deletePreset(id: work.id, topologyKey: office.identity.key)

        model.setAuto(true, presetID: work.id)

        XCTAssertEqual(dialogs.errors.count, 1)
        XCTAssertEqual(rowNames(model), [])
    }

    // MARK: 工具

    private func rowNames(_ model: PresetManagerModel) -> [String] {
        model.state.selected?.rows.map(\.name) ?? []
    }

    @discardableResult
    private func save(_ name: String, on topology: ObservedTopology) throws -> Preset {
        defer { clock = clock.addingTimeInterval(60) }
        return try store.addPreset(name: name, snapshot: snapshot(marker: "old"), topology: topology)
    }

    private func snapshot(marker: String) -> Snapshot {
        Snapshot(capturedAt: clock, topology: [],
                 spaces: [SnapshotSpace(displayUUID: "BUILTIN", index: 1, kind: .user, fullscreenAppBundleID: marker)],
                 windows: [])
    }

    private func makeModel(captureMarker: String = "new") -> PresetManagerModel {
        let overwrite = OverwritePresetFlow(
            store: store,
            capture: { [unowned self] in LayoutCapture(snapshot: snapshot(marker: captureMarker), topology: current) },
            availability: { [unowned self] in availability },
            confirm: dialogs,
            captureExecutor: { $0() },
            mainExecutor: { $0() })
        return PresetManagerModel(store: store,
                                  topologyProvider: { [unowned self] in current },
                                  overwrite: overwrite,
                                  restore: { [unowned self] id, key in restored.append((id, key)) },
                                  dialogs: dialogs,
                                  currentSpaces: { [unowned self] in liveSpaces },
                                  appName: { ["com.apple.Terminal": "终端"][$0] },
                                  timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    private func topology(_ screens: [(String, String, Double)]) -> ObservedTopology {
        ObservedTopology(screens: screens.map { uuid, name, x in
            TopologyScreen(uuid: uuid, name: name, frame: CGRect(x: x, y: 0, width: 1512, height: 982),
                           pixelWidth: 3024, pixelHeight: 1964, rotation: 0, isMirrored: false)
        })
    }

    private var laptop: ObservedTopology { topology([("BUILTIN", "内置", 0)]) }
    private var office: ObservedTopology { topology([("BUILTIN", "内置", 0), ("LG-1", "LG HDR 4K", 1512)]) }
}
