import CoreGraphics
import XCTest
@testable import Core

// VerifyBaselineTests — 验证器比对基准口径（spec §7）。
// 接缝：VerifyBaseline.parse（参数 → 基准来源）与 VerifyBaseline.resolve（来源 + 预设存储 + 当前拓扑 → 快照）。
final class VerifyBaselineTests: XCTestCase {
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

    private func screen(_ uuid: String, _ x: CGFloat, mirrored: Bool = false) -> TopologyScreen {
        TopologyScreen(uuid: uuid, name: "D", frame: CGRect(x: x, y: 0, width: 1000, height: 800),
                       pixelWidth: 2000, pixelHeight: 1600, rotation: 0, isMirrored: mirrored)
    }
    private func dual(mirrored: Bool = false) -> ObservedTopology {
        ObservedTopology(screens: [screen(laptop, -1000, mirrored: mirrored), screen(main, 0, mirrored: mirrored)])
    }
    private func single() -> ObservedTopology {
        ObservedTopology(screens: [screen(laptop, 0)])
    }
    private func snap(_ tag: String) -> Snapshot {
        Snapshot(capturedAt: Date(timeIntervalSince1970: 0), topology: [], spaces: [],
                 windows: [SnapshotWindow(bundleID: "app.\(tag)", title: tag, siblingIndex: 0,
                                          displayUUID: laptop, spaceIndex: 1,
                                          x: 0, y: 0, w: 0.5, h: 0.5, minimized: false)])
    }

    // MARK: 基准解析

    /// 缺省基准 = 当前拓扑最近一次恢复所用的预设（不是自动、不是最近保存）
    func testDefaultBaselineIsLastRestoredPresetOfCurrentTopology() throws {
        let work = try store.addPreset(name: "工作", snapshot: snap("a"), topology: dual())
        let demo = try store.addPreset(name: "演示", snapshot: snap("b"), topology: dual())
        _ = try store.addPreset(name: "阅读", snapshot: snap("c"), topology: dual())
        try store.recordRestored(presetID: demo.id, topologyKey: dual().identity.key)
        // 其他拓扑的最近恢复不串
        let solo = try store.addPreset(name: "单屏", snapshot: snap("s"), topology: single())
        try store.recordRestored(presetID: solo.id, topologyKey: single().identity.key)

        let preset = try VerifyBaseline.lastRestored.resolvePreset(in: store, topology: dual())
        XCTAssertEqual(preset.id, demo.id)
        XCTAssertEqual(preset.snapshot, snap("b"))
        XCTAssertNotEqual(preset.id, work.id, "自动预设不是缺省基准")
    }

    /// 当前拓扑从未恢复过 / 无预设 / 镜像中 → 无比对基准
    func testDefaultBaselineMissingIsNoBaseline() throws {
        assertNoBaseline(try VerifyBaseline.lastRestored.resolvePreset(in: store, topology: dual()), "拓扑无预设")
        _ = try store.addPreset(name: "工作", snapshot: snap("a"), topology: dual())
        assertNoBaseline(try VerifyBaseline.lastRestored.resolvePreset(in: store, topology: dual()), "从未恢复")

        let work = try XCTUnwrap(store.topology(key: dual().identity.key)?.presets.first)
        try store.recordRestored(presetID: work.id, topologyKey: dual().identity.key)
        assertNoBaseline(try VerifyBaseline.lastRestored.resolvePreset(in: store, topology: dual(mirrored: true)), "镜像中")
    }

    /// --preset 按名称取当前拓扑下的预设（名称去首尾空白后精确比较）；别的拓扑同名预设不算
    func testNamedPresetResolvesWithinCurrentTopologyOnly() throws {
        XCTAssertThrowsError(try VerifyBaseline.preset(name: "工作").resolvePreset(in: store, topology: dual())) { error in
            XCTAssertEqual(error as? VerifyBaselineError, .presetNotFound(name: "工作", available: []), "拓扑无预设")
        }
        _ = try store.addPreset(name: "工作", snapshot: snap("a"), topology: dual())
        let demo = try store.addPreset(name: "演示", snapshot: snap("b"), topology: dual())
        _ = try store.addPreset(name: "单屏", snapshot: snap("s"), topology: single())

        XCTAssertEqual(try VerifyBaseline.preset(name: " 演示 ").resolvePreset(in: store, topology: dual()).id, demo.id)
        XCTAssertThrowsError(try VerifyBaseline.preset(name: "单屏").resolvePreset(in: store, topology: dual())) { error in
            XCTAssertEqual(error as? VerifyBaselineError, .presetNotFound(name: "单屏", available: ["工作", "演示"]))
        }
    }

    private func assertNoBaseline(_ expr: @autoclosure () throws -> Preset, _ message: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), message, file: file, line: line) { error in
            guard case VerifyBaselineError.noBaseline = error else {
                return XCTFail("\(message): \(error)", file: file, line: line)
            }
        }
    }

    // MARK: 参数

    /// 三种来源：缺省 = 最近恢复预设；--preset <名称>；--snapshot <文件>
    func testParseThreeSources() throws {
        XCTAssertEqual(try VerifyBaseline.parse([]), .lastRestored)
        XCTAssertEqual(try VerifyBaseline.parse(["--preset", "工作"]), .preset(name: "工作"))
        XCTAssertEqual(try VerifyBaseline.parse(["--snapshot", "/tmp/a.json"]), .snapshotFile(path: "/tmp/a.json"))
    }

    /// --preset 与 --snapshot 互斥；缺值、未知参数、重复给定都是用法错误
    func testParseRejectsConflictingOrMalformedArguments() {
        for args in [["--preset", "工作", "--snapshot", "/tmp/a.json"],
                     ["--preset", "工作", "--preset", "演示"],
                     ["--preset"],
                     ["--snapshot"],
                     ["--bogus"]] {
            XCTAssertThrowsError(try VerifyBaseline.parse(args), "\(args)") { error in
                guard case VerifyBaselineError.usage = error else { return XCTFail("\(args): \(error)") }
            }
        }
    }
}
