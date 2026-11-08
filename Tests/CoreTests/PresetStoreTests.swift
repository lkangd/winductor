import CoreGraphics
import XCTest
@testable import Core

// PresetStoreTests — 预设存储验收（spec §3.2/§4.1/§4.2/§4.4）。
// 接缝：PresetStore 公开 API（真实临时目录落盘；损坏用例直接改写文件作故障注入）。
final class PresetStoreTests: XCTestCase {
    private var root: URL!
    private var store: PresetStore!
    private var clock: Date!

    private let main = "11111111-1111-1111-1111-111111111111"
    private let laptop = "22222222-2222-2222-2222-222222222222"

    override func setUpWithError() throws {
        root = try makeTempDir()
        clock = Date(timeIntervalSince1970: 1_000_000)
        store = PresetStore(directory: root, now: { [unowned self] in
            self.clock = self.clock.addingTimeInterval(60)
            return self.clock
        })
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func screen(_ uuid: String, _ x: CGFloat, name: String = "D",
                        mirrored: Bool = false) -> TopologyScreen {
        TopologyScreen(uuid: uuid, name: name, frame: CGRect(x: x, y: 0, width: 1000, height: 800),
                       pixelWidth: 2000, pixelHeight: 1600, rotation: 0, isMirrored: mirrored)
    }

    /// 两屏并排（内置在左）
    private func dual() -> ObservedTopology {
        ObservedTopology(screens: [screen(laptop, -1000, name: "内置"), screen(main, 0, name: "DELL")])
    }

    /// 单屏
    private func single() -> ObservedTopology {
        ObservedTopology(screens: [screen(laptop, 0, name: "内置")])
    }

    private func snap(_ tag: String) -> Snapshot {
        Snapshot(capturedAt: Date(timeIntervalSince1970: 0),
                 topology: [], spaces: [],
                 windows: [SnapshotWindow(bundleID: "app.\(tag)", title: tag, siblingIndex: 0,
                                          displayUUID: laptop, spaceIndex: 1,
                                          x: 0, y: 0, w: 0.5, h: 0.5, minimized: false)])
    }

    // MARK: §4.2 自动标记

    /// 拓扑下无任何预设时新建的第一个预设默认自动
    func testFirstPresetInEmptyTopologyIsAuto() throws {
        let preset = try store.addPreset(name: "工作", snapshot: snap("a"), topology: dual())
        XCTAssertTrue(preset.isAuto)

        let listed = store.topologies()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].key, dual().identity.key)
        XCTAssertEqual(listed[0].presets.map(\.name), ["工作"])
        XCTAssertEqual(listed[0].autoPreset?.id, preset.id)
        XCTAssertEqual(listed[0].presets[0].snapshot, snap("a"))
    }

    /// 已有预设时新建的不自动；用户关掉自动后，之后新建的也不会自动成为自动
    func testAfterTurningAutoOffNewPresetsStayNonAuto() throws {
        let first = try store.addPreset(name: "工作", snapshot: snap("a"), topology: dual())
        let second = try store.addPreset(name: "演示", snapshot: snap("b"), topology: dual())
        XCTAssertFalse(second.isAuto)

        try store.setAuto(false, presetID: first.id, topologyKey: dual().identity.key)
        let third = try store.addPreset(name: "阅读", snapshot: snap("c"), topology: dual())
        XCTAssertFalse(third.isAuto)
        XCTAssertNil(store.topology(key: dual().identity.key)?.autoPreset, "关掉自动后拓扑为「无自动」")
    }

    /// 每拓扑至多一个自动：设某预设为自动 = 同拓扑其他预设自动清除；其他拓扑不受影响
    func testSettingAutoClearsOtherAutoInSameTopologyOnly() throws {
        let work = try store.addPreset(name: "工作", snapshot: snap("a"), topology: dual())
        let demo = try store.addPreset(name: "演示", snapshot: snap("b"), topology: dual())
        let solo = try store.addPreset(name: "单屏", snapshot: snap("c"), topology: single())

        try store.setAuto(true, presetID: demo.id, topologyKey: dual().identity.key)

        let presets = try XCTUnwrap(store.topology(key: dual().identity.key)).presets
        XCTAssertEqual(presets.filter(\.isAuto).map(\.id), [demo.id])
        XCTAssertFalse(presets.first { $0.id == work.id }!.isAuto)
        XCTAssertEqual(store.topology(key: single().identity.key)?.autoPreset?.id, solo.id)
    }

    /// 删除自动预设：不转移标记，拓扑变为「无自动」
    func testDeletingAutoPresetDoesNotTransferAuto() throws {
        let work = try store.addPreset(name: "工作", snapshot: snap("a"), topology: dual())
        let demo = try store.addPreset(name: "演示", snapshot: snap("b"), topology: dual())

        try store.deletePreset(id: work.id, topologyKey: dual().identity.key)

        let topology = try XCTUnwrap(store.topology(key: dual().identity.key))
        XCTAssertEqual(topology.presets.map(\.id), [demo.id])
        XCTAssertNil(topology.autoPreset)
    }

    /// 覆盖预设：保留自动标记与名称，更新快照与保存时间；展示数据随之刷新
    func testOverwriteKeepsAutoAndNameUpdatesSnapshotSavedAtAndDisplays() throws {
        let work = try store.addPreset(name: "工作", snapshot: snap("a"), topology: dual())
        // 同一拓扑（只改了分辨率与屏名）：展示数据刷新、身份不变
        let renamedScreens = ObservedTopology(screens: [
            TopologyScreen(uuid: laptop, name: "内置 Retina", frame: CGRect(x: -1000, y: 0, width: 1000, height: 800),
                           pixelWidth: 3000, pixelHeight: 2400, rotation: 0, isMirrored: false),
            screen(main, 0, name: "DELL")])
        XCTAssertEqual(renamedScreens.identity, dual().identity)

        let updated = try store.overwritePreset(id: work.id, snapshot: snap("b"), topology: renamedScreens)

        XCTAssertEqual(updated.name, "工作")
        XCTAssertTrue(updated.isAuto)
        XCTAssertGreaterThan(updated.savedAt, work.savedAt)
        let topology = try XCTUnwrap(store.topology(key: dual().identity.key))
        XCTAssertEqual(topology.presets, [updated])
        XCTAssertEqual(topology.presets[0].snapshot, snap("b"))
        XCTAssertEqual(topology.displays.map(\.name), ["内置 Retina", "DELL"])
        XCTAssertEqual(topology.displays[0].pixelWidth, 3000)
    }

    // MARK: §4.1 名称唯一

    /// 同拓扑重名拒绝（新建与改名），跨拓扑重名允许
    func testDuplicateNameRejectedWithinTopologyAllowedAcross() throws {
        let work = try store.addPreset(name: "工作", snapshot: snap("a"), topology: dual())
        let demo = try store.addPreset(name: "演示", snapshot: snap("b"), topology: dual())

        XCTAssertThrowsError(try store.addPreset(name: "工作", snapshot: snap("c"), topology: dual())) {
            XCTAssertEqual($0 as? PresetStoreError, .duplicateName("工作"))
        }
        XCTAssertThrowsError(try store.renamePreset(id: demo.id, topologyKey: dual().identity.key, to: "工作")) {
            XCTAssertEqual($0 as? PresetStoreError, .duplicateName("工作"))
        }
        XCTAssertNoThrow(try store.addPreset(name: "工作", snapshot: snap("d"), topology: single()))
        XCTAssertNoThrow(try store.renamePreset(id: work.id, topologyKey: dual().identity.key, to: "工作"),
                         "改成自己现有的名字不算撞名")

        try store.renamePreset(id: demo.id, topologyKey: dual().identity.key, to: "开会")
        let names = store.topology(key: dual().identity.key)?.presets.map(\.name)
        XCTAssertEqual(names, ["工作", "开会"])
        XCTAssertEqual(store.topology(key: dual().identity.key)?.autoPreset?.id, work.id, "改名不动自动标记")
    }

    /// 名称首尾空白不计；空名拒绝
    func testNameIsTrimmedAndEmptyRejected() throws {
        let work = try store.addPreset(name: "  工作 ", snapshot: snap("a"), topology: dual())
        XCTAssertEqual(work.name, "工作")
        XCTAssertThrowsError(try store.addPreset(name: "工作", snapshot: snap("b"), topology: dual()))
        XCTAssertThrowsError(try store.addPreset(name: "   ", snapshot: snap("b"), topology: dual())) {
            XCTAssertEqual($0 as? PresetStoreError, .emptyName)
        }
    }

    // MARK: §3.2 别名 / §4.4 最近恢复 / §3.3 镜像

    /// 别名可设可清（空白 = 清除，回到默认屏名组合）；新实例读回一致（落盘）
    func testAliasSetAndClearedPersisted() throws {
        try store.addPreset(name: "工作", snapshot: snap("a"), topology: dual())
        let key = dual().identity.key

        try store.setAlias("  家里  ", topologyKey: key)
        XCTAssertEqual(PresetStore(directory: root).topology(key: key)?.alias, "家里")
        try store.setAlias("   ", topologyKey: key)
        XCTAssertNil(PresetStore(directory: root).topology(key: key)?.alias)
        XCTAssertThrowsError(try store.setAlias("x", topologyKey: single().identity.key), "未知拓扑拒绝")
    }

    /// 最近恢复预设 id 按拓扑记录；删除该预设后记录清除
    func testRecordRestoredPerTopologyClearedOnDelete() throws {
        let work = try store.addPreset(name: "工作", snapshot: snap("a"), topology: dual())
        let demo = try store.addPreset(name: "演示", snapshot: snap("b"), topology: dual())
        let solo = try store.addPreset(name: "单屏", snapshot: snap("c"), topology: single())

        try store.recordRestored(presetID: demo.id, topologyKey: dual().identity.key)
        try store.recordRestored(presetID: solo.id, topologyKey: single().identity.key)
        XCTAssertEqual(store.topology(key: dual().identity.key)?.lastRestoredPresetID, demo.id)
        XCTAssertEqual(store.topology(key: single().identity.key)?.lastRestoredPresetID, solo.id)
        XCTAssertThrowsError(try store.recordRestored(presetID: "nope", topologyKey: dual().identity.key))

        try store.deletePreset(id: demo.id, topologyKey: dual().identity.key)
        XCTAssertNil(store.topology(key: dual().identity.key)?.lastRestoredPresetID)
        XCTAssertEqual(store.topology(key: dual().identity.key)?.autoPreset?.id, work.id)
    }

    /// 镜像中禁止保存（spec §3.3）
    func testSavingWhileMirroredIsRejected() {
        let mirrored = ObservedTopology(screens: [screen(laptop, 0, mirrored: true), screen(main, 0, mirrored: true)])
        XCTAssertThrowsError(try store.addPreset(name: "工作", snapshot: snap("a"), topology: mirrored)) {
            XCTAssertEqual($0 as? PresetStoreError, .mirrored)
        }
        XCTAssertEqual(store.topologies(), [])
        let work = try? store.addPreset(name: "工作", snapshot: snap("a"), topology: dual())
        XCTAssertThrowsError(try store.overwritePreset(id: work?.id ?? "", snapshot: snap("b"), topology: mirrored)) {
            XCTAssertEqual($0 as? PresetStoreError, .mirrored)
        }
    }

    // MARK: 损坏隔离 / 版本拒用 / 旧文件不读

    private func files(in key: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(key).path).sorted()
    }

    /// 单个预设文件损坏：隔离改名 .corrupt-<时间戳>，同拓扑其他预设与其他拓扑照常
    func testCorruptPresetIsQuarantinedOthersUnaffected() throws {
        let work = try store.addPreset(name: "工作", snapshot: snap("a"), topology: dual())
        let demo = try store.addPreset(name: "演示", snapshot: snap("b"), topology: dual())
        let solo = try store.addPreset(name: "单屏", snapshot: snap("c"), topology: single())
        let key = dual().identity.key
        try Data("{\"version\": 1, 截断".utf8)
            .write(to: root.appendingPathComponent(key).appendingPathComponent("preset-\(work.id).json"))

        let topology = try XCTUnwrap(store.topology(key: key))
        XCTAssertEqual(topology.presets.map(\.id), [demo.id])
        XCTAssertNil(topology.autoPreset, "自动预设已不可用：不转移")
        XCTAssertTrue(try files(in: key).contains { $0.hasPrefix("preset-\(work.id).json.corrupt-") })
        XCTAssertFalse(try files(in: key).contains("preset-\(work.id).json"))
        XCTAssertEqual(store.topology(key: single().identity.key)?.presets.map(\.id), [solo.id])
        XCTAssertNoThrow(try store.addPreset(name: "工作", snapshot: snap("d"), topology: dual()),
                         "损坏预设不再占用名称")
    }

    /// 拓扑元数据损坏：隔离；预设照常列出（别名/自动/最近恢复丢失），下次保存重建元数据
    func testCorruptTopologyMetaIsQuarantinedPresetsSurvive() throws {
        let work = try store.addPreset(name: "工作", snapshot: snap("a"), topology: dual())
        try store.setAlias("家里", topologyKey: dual().identity.key)
        let key = dual().identity.key
        try Data("garbage".utf8).write(to: root.appendingPathComponent(key).appendingPathComponent("topology.json"))

        let topology = try XCTUnwrap(store.topology(key: key))
        XCTAssertEqual(topology.presets.map(\.id), [work.id])
        XCTAssertNil(topology.alias)
        XCTAssertTrue(try files(in: key).contains { $0.hasPrefix("topology.json.corrupt-") })

        try store.addPreset(name: "演示", snapshot: snap("b"), topology: dual())
        let rebuilt = try XCTUnwrap(store.topology(key: key))
        XCTAssertEqual(rebuilt.displays.map(\.name), ["内置", "DELL"])
        XCTAssertEqual(rebuilt.canonicalDescription, dual().identity.canonicalDescription)
    }

    /// 未知更高版本：拒用不迁移，原位保留不隔离
    func testFutureVersionPresetIsSkippedNotQuarantined() throws {
        let work = try store.addPreset(name: "工作", snapshot: snap("a"), topology: dual())
        let key = dual().identity.key
        let url = root.appendingPathComponent(key).appendingPathComponent("preset-\(work.id).json")
        let bumped = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "\"version\" : \(presetSchemaVersion)", with: "\"version\" : 99")
        try bumped.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(store.topology(key: key)?.presets, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "版本拒用原位保留")
    }

    /// 旧布局 live-*/history-*/undo-* 不读取、不动
    func testLegacySnapshotFilesAreIgnored() throws {
        let legacy = ["live-A-B.json", "history-1-A-B.json", "undo-A-B.json"]
        for name in legacy {
            try snap("old").encoded().write(to: root.appendingPathComponent(name))
        }
        XCTAssertEqual(store.topologies(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), legacy.sorted())
    }

    // MARK: 回滚快照位置

    /// 回滚快照每拓扑一份、落在拓扑目录内；只有回滚快照的目录不算已存拓扑
    func testUndoSnapshotLivesPerTopologyAndDoesNotCreateListedTopology() throws {
        let dualURL = store.undoURL(topologyKey: dual().identity.key)
        let singleURL = store.undoURL(topologyKey: single().identity.key)
        XCTAssertNotEqual(dualURL, singleURL)
        XCTAssertEqual(dualURL.deletingLastPathComponent().lastPathComponent, dual().identity.key)

        try SnapshotStore.atomicWrite(try snap("u").encoded(), to: dualURL)
        XCTAssertEqual(store.topologies(), [])
        try store.addPreset(name: "工作", snapshot: snap("a"), topology: dual())
        XCTAssertEqual(store.topologies().map(\.presets.count), [1], "回滚快照不被当作预设")
    }
}
