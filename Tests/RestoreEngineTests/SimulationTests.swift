@testable import Core
import CoreGraphics
import Foundation
import RestoreEngine
import XCTest

// SimulationTests — simulate-restore 干跑接缝的测试（retro 优化：多屏行为免硬件可验）。
// 钉住三件事：fixture 解码默认值、三屏全匹配干跑走真实管线、部分拓扑按「目标屏缺失」计 skip。

final class SimulationTests: XCTestCase {
    // MARK: - fixture 解码

    func testFixtureDecodeWithDefaults() throws {
        let json = """
        {"displays":[{"uuid":"U1","x":0,"y":0,"w":1512,"h":982}],
         "spaces":[],
         "windows":[{"windowID":1,"pid":100,"bundleID":"com.app.A","title":"A",
                     "x":10,"y":20,"w":300,"h":200,"spaceID":11}]}
        """
        let fixture = try JSONDecoder().decode(SimulatedTopologyFixture.self, from: Data(json.utf8))
        XCTAssertEqual(fixture.displays.first?.rotation, 0, "rotation 缺省 0")
        XCTAssertEqual(fixture.windows.first?.onscreen, false, "onscreen 缺省 false（同 kCGWindowIsOnscreen 缺键 = 不在屏）")
        XCTAssertEqual(fixture.windows.first?.minimized, false, "minimized 缺省 false")
        XCTAssertTrue(fixture.layers.bridge, "layers 缺省全可用")
        XCTAssertTrue(fixture.layers.fullscreen)
        XCTAssertTrue(fixture.layers.minimized)
    }

    // MARK: - fixture 拓扑身份（simulate-restore 按预设名在 fixture 拓扑下查预设）

    /// fixture 的拓扑身份 = 同排列同旋转的实况屏算出的身份（屏名/分辨率不参与）
    func testFixtureTopologyIdentityMatchesEquivalentObservedScreens() {
        let fixture = SimulatedTopologyFixture(
            displays: [SimulatedTopologyFixture.Display(uuid: "U2", x: 1512, y: 0, w: 1920, h: 1080, rotation: 90),
                       SimulatedTopologyFixture.Display(uuid: "U1", x: 0, y: 0, w: 1512, h: 982)],
            spaces: [], windows: [])
        let observed = ObservedTopology(screens: [
            TopologyScreen(uuid: "U1", name: "内置", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                           pixelWidth: 3024, pixelHeight: 1964, rotation: 0, isMirrored: false),
            TopologyScreen(uuid: "U2", name: "DELL", frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                           pixelWidth: 1920, pixelHeight: 1080, rotation: 90, isMirrored: false),
        ])
        XCTAssertEqual(fixture.topologyIdentity, observed.identity)
    }

    // MARK: - 三屏全匹配干跑

    /// 快照 3 屏各 1 窗；fixture 同拓扑、存活窗在错误 Space 且几何漂移 → 管线应全匹配全恢复。
    func testThreeDisplayHappyPathDrivesRealPipeline() throws {
        let displays = [
            SimulatedTopologyFixture.Display(uuid: "U1", x: 0, y: 0, w: 1512, h: 982),
            SimulatedTopologyFixture.Display(uuid: "U2", x: 1512, y: 0, w: 1920, h: 1080),
            SimulatedTopologyFixture.Display(uuid: "U3", x: 0, y: 982, w: 2560, h: 1440),
        ]
        // 每屏 1 个用户桌面 Space；存活窗全部挂在错误 Space 99 上（逼 L2 桥接真实开火）
        let spaces = [
            SimulatedTopologyFixture.Space(displayUUID: "U1", spaceID: 11, index: 1, kind: 0),
            SimulatedTopologyFixture.Space(displayUUID: "U2", spaceID: 12, index: 1, kind: 0),
            SimulatedTopologyFixture.Space(displayUUID: "U3", spaceID: 13, index: 1, kind: 0),
        ]
        let windows = [
            SimulatedTopologyFixture.Window(windowID: 1, pid: 101, bundleID: "com.app.A", title: "Doc",
                                            x: 30, y: 40, w: 800, h: 600, onscreen: true, spaceID: 99),
            SimulatedTopologyFixture.Window(windowID: 2, pid: 102, bundleID: "com.app.B", title: "Mail",
                                            x: 1600, y: 60, w: 900, h: 700, onscreen: true, spaceID: 99),
            SimulatedTopologyFixture.Window(windowID: 3, pid: 103, bundleID: "com.app.C", title: "Code",
                                            x: 100, y: 1100, w: 1200, h: 800, onscreen: true, spaceID: 99),
        ]
        let fixture = SimulatedTopologyFixture(displays: displays, spaces: spaces, windows: windows)

        // 快照：同 3 屏、每窗在自己屏的 (0.1, 0.1, 0.5, 0.5) 比例位、spaceIndex 1
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [
                TopologyDisplay(uuid: "U1", localizedName: "Built-in",
                                frame: .init(x: 0, y: 0, w: 1512, h: 982), orientation: 0),
                TopologyDisplay(uuid: "U2", localizedName: "Left Ext",
                                frame: .init(x: 1512, y: 0, w: 1920, h: 1080), orientation: 0),
                TopologyDisplay(uuid: "U3", localizedName: "Below",
                                frame: .init(x: 0, y: 982, w: 2560, h: 1440), orientation: 0),
            ],
            spaces: [
                SnapshotSpace(displayUUID: "U1", index: 1, kind: .user, fullscreenAppBundleID: nil),
                SnapshotSpace(displayUUID: "U2", index: 1, kind: .user, fullscreenAppBundleID: nil),
                SnapshotSpace(displayUUID: "U3", index: 1, kind: .user, fullscreenAppBundleID: nil),
            ],
            windows: [
                SnapshotWindow(bundleID: "com.app.A", title: "Doc", siblingIndex: 0,
                               displayUUID: "U1", spaceIndex: 1, x: 0.1, y: 0.1, w: 0.5, h: 0.5, minimized: false),
                SnapshotWindow(bundleID: "com.app.B", title: "Mail", siblingIndex: 0,
                               displayUUID: "U2", spaceIndex: 1, x: 0.1, y: 0.1, w: 0.5, h: 0.5, minimized: false),
                SnapshotWindow(bundleID: "com.app.C", title: "Code", siblingIndex: 0,
                               displayUUID: "U3", spaceIndex: 1, x: 0.1, y: 0.1, w: 0.5, h: 0.5, minimized: false),
            ])

        let sink = LogSpy()  // 加锁 sink：L1 8 路并发写日志
        let storeDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("simulate-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storeDir) }

        let (report, actions) = try SimulatedRestore.run(
            snapshot: snapshot, fixture: fixture, log: sink, storeDirectory: storeDir)

        // 管线计数：全匹配全成功（spec §6.3 计数口径）
        XCTAssertEqual(report.matchedCount, 3)
        XCTAssertEqual(report.okCount, 3)
        XCTAssertEqual(report.failCount, 0)
        XCTAssertEqual(report.skipCount, 0)

        // L2 桥接：每窗移到其所属屏当前 Space（快照 displayUUID+spaceIndex → fixture spaceID）
        XCTAssertEqual(actions.bridgeMoves.count, 3)
        XCTAssertEqual(Set(actions.bridgeMoves.map(\.spaceID)), Set<Int64>([11, 12, 13]))

        // L1 几何：比例坐标 × fixture 屏 frame（无旋转轴向互换）= 绝对点位
        XCTAssertEqual(actions.geometryWrites.count, 3)
        let byWindow = Dictionary(uniqueKeysWithValues: actions.geometryWrites.map { ($0.windowID, $0) })
        XCTAssertEqual(byWindow[1]?.position.x ?? -1, 0.1 * 1512, accuracy: 0.5, "U1 窗 x = 比例 × 屏宽")
        XCTAssertEqual(byWindow[2]?.position.x ?? -1, 1512 + 0.1 * 1920, accuracy: 0.5, "U2 窗 x 含屏 origin")
        XCTAssertEqual(byWindow[3]?.position.y ?? -1, 982 + 0.1 * 1440, accuracy: 0.5, "U3 窗 y 含屏 origin")

        // 干跑不落真实库：undo 快照写进了临时 store 目录
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeDir.path), "回滚快照写临时目录（§7.4 管线路径不变）")
    }

    // MARK: - 部分拓扑

    /// 快照 2 屏、fixture 只插 1 屏 → 目标屏缺失的窗计 skip，在位屏的窗照常恢复（spec §6.4）。
    func testPartialTopologySkipsMissingDisplay() throws {
        let fixture = SimulatedTopologyFixture(
            displays: [SimulatedTopologyFixture.Display(uuid: "U1", x: 0, y: 0, w: 1512, h: 982)],
            spaces: [SimulatedTopologyFixture.Space(displayUUID: "U1", spaceID: 11, index: 1, kind: 0)],
            windows: [
                SimulatedTopologyFixture.Window(windowID: 1, pid: 101, bundleID: "com.app.A", title: "Doc",
                                                x: 30, y: 40, w: 800, h: 600, onscreen: true, spaceID: 99),
                SimulatedTopologyFixture.Window(windowID: 2, pid: 102, bundleID: "com.app.B", title: "Mail",
                                                x: 1600, y: 60, w: 900, h: 700, onscreen: true, spaceID: 98),
            ])
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [
                TopologyDisplay(uuid: "U1", localizedName: "Built-in",
                                frame: .init(x: 0, y: 0, w: 1512, h: 982), orientation: 0),
                TopologyDisplay(uuid: "U2", localizedName: "Gone",
                                frame: .init(x: 1512, y: 0, w: 1920, h: 1080), orientation: 0),
            ],
            spaces: [
                SnapshotSpace(displayUUID: "U1", index: 1, kind: .user, fullscreenAppBundleID: nil),
                SnapshotSpace(displayUUID: "U2", index: 1, kind: .user, fullscreenAppBundleID: nil),
            ],
            windows: [
                SnapshotWindow(bundleID: "com.app.A", title: "Doc", siblingIndex: 0,
                               displayUUID: "U1", spaceIndex: 1, x: 0.1, y: 0.1, w: 0.5, h: 0.5, minimized: false),
                SnapshotWindow(bundleID: "com.app.B", title: "Mail", siblingIndex: 0,
                               displayUUID: "U2", spaceIndex: 1, x: 0.1, y: 0.1, w: 0.5, h: 0.5, minimized: false),
            ])

        let storeDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("simulate-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storeDir) }

        let (report, actions) = try SimulatedRestore.run(
            snapshot: snapshot, fixture: fixture, log: LogSpy(),
            storeDirectory: storeDir)

        XCTAssertEqual(report.okCount, 1, "在位屏的窗照常恢复")
        XCTAssertEqual(report.skipCount, 1, "目标屏缺失计 skip")
        XCTAssertEqual(report.failCount, 0)
        XCTAssertEqual(actions.bridgeMoves.count, 1)
        XCTAssertEqual(actions.bridgeMoves.first?.spaceID, 11)
    }
}

/// 测试用日志收集器（照 ConsoleLogSink 口径）
