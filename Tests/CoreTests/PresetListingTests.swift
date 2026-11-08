import CoreGraphics
import XCTest
@testable import Core

// PresetListingTests — DebugCLI list-presets 的人读输出（全部拓扑与预设，标当前拓扑、自动、最近恢复）。
// 接缝：PresetListing.render（真实临时目录 PresetStore 造数据，期望输出为手写字面量）。
final class PresetListingTests: XCTestCase {
    private var root: URL!
    private var store: PresetStore!
    private var clock: Date!
    private var nextID = 0

    private let main = "11111111-1111-1111-1111-111111111111"
    private let laptop = "22222222-2222-2222-2222-222222222222"
    private let utc = TimeZone(identifier: "UTC")!

    override func setUpWithError() throws {
        root = try makeTempDir()
        clock = Date(timeIntervalSince1970: 1_000_000)
        store = PresetStore(directory: root, now: { [unowned self] in
            self.clock = self.clock.addingTimeInterval(60)
            return self.clock
        }, makeID: { [unowned self] in
            self.nextID += 1
            return "P\(self.nextID)"
        })
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func screen(_ uuid: String, _ x: CGFloat, name: String, mirrored: Bool = false) -> TopologyScreen {
        TopologyScreen(uuid: uuid, name: name, frame: CGRect(x: x, y: 0, width: 1000, height: 800),
                       pixelWidth: 2000, pixelHeight: 1600, rotation: 0, isMirrored: mirrored)
    }
    private func dual(mirrored: Bool = false) -> ObservedTopology {
        ObservedTopology(screens: [screen(laptop, -1000, name: "内置", mirrored: mirrored),
                                   screen(main, 0, name: "DELL", mirrored: mirrored)])
    }
    private func single() -> ObservedTopology {
        ObservedTopology(screens: [screen(laptop, 0, name: "内置")])
    }
    private func snap() -> Snapshot {
        Snapshot(capturedAt: Date(timeIntervalSince1970: 0), topology: [], spaces: [], windows: [])
    }

    /// 两个拓扑：当前拓扑带别名、自动与最近恢复标记；另一拓扑无标记
    func testListsAllTopologiesMarkingCurrentAutoAndLastRestored() throws {
        let work = try store.addPreset(name: "工作", snapshot: snap(), topology: dual())      // 13:47，自动
        let demo = try store.addPreset(name: "演示", snapshot: snap(), topology: dual())      // 13:48
        _ = try store.addPreset(name: "单屏", snapshot: snap(), topology: single())           // 13:49，自动
        try store.recordRestored(presetID: demo.id, topologyKey: dual().identity.key)
        try store.setAlias("办公室", topologyKey: dual().identity.key)
        XCTAssertTrue(work.isAuto)

        let dualKey = dual().identity.key, singleKey = single().identity.key
        let blocks = [
            (dualKey, """
            拓扑 \(dualKey)（办公室）  ← 当前
              屏：内置 2000×1600 · DELL 2000×1600
              · 工作  1970-01-12 13:47  [自动]  id=P1
              · 演示  1970-01-12 13:48  [最近恢复]  id=P2
            """),
            (singleKey, """
            拓扑 \(singleKey)
              屏：内置 2000×1600
              · 单屏  1970-01-12 13:49  [自动]  id=P3
            """),
        ].sorted { $0.0 < $1.0 }.map(\.1)

        XCTAssertEqual(PresetListing.render(store.topologies(), current: dual(), timeZone: utc),
                       blocks.joined(separator: "\n\n"))
    }

    /// 当前拓扑没存过 → 末尾补一行说明；空库同理；镜像中说明无当前拓扑
    func testCurrentTopologyWithoutPresetsAndMirroredAreSpelledOut() throws {
        XCTAssertEqual(PresetListing.render([], current: single(), timeZone: utc),
                       "当前拓扑 \(single().identity.key)：无预设")

        _ = try store.addPreset(name: "工作", snapshot: snap(), topology: dual())
        let dualKey = dual().identity.key
        let dualBlock = """
        拓扑 \(dualKey)
          屏：内置 2000×1600 · DELL 2000×1600
          · 工作  1970-01-12 13:47  [自动]  id=P1
        """
        XCTAssertEqual(PresetListing.render(store.topologies(), current: single(), timeZone: utc),
                       dualBlock + "\n\n当前拓扑 \(single().identity.key)：无预设")
        XCTAssertEqual(PresetListing.render(store.topologies(), current: dual(mirrored: true), timeZone: utc),
                       dualBlock + "\n\n当前：镜像中，无拓扑")
    }
}
