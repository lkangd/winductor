import Core
import CoreGraphics
import Foundation
import XCTest
@testable import SnapshotEngine

// SnapshotComposerTests — 快照内容映射验收（spec §7.3/§7.5）：
//   displayUUID 按 bounds 交集最大者、spaceIndex 经 SpaceProviding、兄弟序先 y 后 x、
//   离屏读 AXMinimized、整屏候选读 AXFullScreen（全屏不进 windows、归记全屏 Space）、
//   Space 数据缺失降级（spaces=[]、spaceIndex=1）。
final class SnapshotComposerTests: XCTestCase {
    private let ax = FakeAXProber()
    private let displayA = "AAAA-1111-1111-1111-111111111111"
    private let displayB = "BBBB-2222-2222-2222-222222222222"

    private func composer(spaces: SpaceProviding?) -> SnapshotComposer {
        SnapshotComposer(spaces: spaces, ax: ax)
    }

    private func compose(_ composer: SnapshotComposer,
                         _ windows: [CGWindowSample],
                         displays: [Displays.Info],
                         capturedAt: Date = Date(timeIntervalSince1970: 0)) -> Snapshot {
        composer.compose(sample: windows, displays: displays, capturedAt: capturedAt)
    }

    private func window(_ id: UInt32, bundleID: String = "com.a", title: String,
                        x: Double, y: Double, w: Double = 400, h: Double = 300,
                        onscreen: Bool = true, pid: Int32 = 42) -> CGWindowSample {
        CGWindowSample(windowID: id, pid: pid, bundleID: bundleID, title: title,
                       bounds: CGRect(x: x, y: y, width: w, height: h), isOnscreen: onscreen)
    }

    /// displayUUID = bounds 交集最大者；同积平局取左者（displays 已按左→右序）
    func testDisplayAssignmentByLargestBoundsIntersection() {
        let a = fakeDisplay(displayA, x: 0, y: 0, w: 1000, h: 1000)
        let b = fakeDisplay(displayB, x: 1000, y: 0, w: 1000, h: 1000)
        let tie = compose(composer(spaces: nil),
                          [window(1, title: "t", x: 900, y: 100, w: 200, h: 200)],
                          displays: [a, b])
        XCTAssertEqual(tie.windows.first?.displayUUID, displayA, "两侧交集各 100，平局取左者")

        let leftHeavy = compose(composer(spaces: nil),
                                [window(1, title: "t", x: 850, y: 100, w: 200, h: 200)],
                                displays: [a, b])
        XCTAssertEqual(leftHeavy.windows.first?.displayUUID, displayA, "850..1050 交集左 150 > 右 50")

        let rightHeavy = compose(composer(spaces: nil),
                                 [window(1, title: "t", x: 1050, y: 100, w: 200, h: 200)],
                                 displays: [a, b])
        XCTAssertEqual(rightHeavy.windows.first?.displayUUID, displayB, "1050..1250 交集右 150 > 左 50")
    }

    /// 实测缺陷回归：非可见 Space 后台窗的 AX frame 过期，可能与错误屏相交——
    /// 归属必须以 Space 所有权为权威，frame 仅在无 Space 归属时兜底
    func testBackgroundWindowAttributionPrefersSpaceOwnershipOverFrame() throws {
        let a = fakeDisplay(displayA, x: 0, y: 0, w: 1000, h: 1000)
        let b = fakeDisplay(displayB, x: 1000, y: 0, w: 1000, h: 1000)
        // 窗口 frame 落在 B 屏区域内，但 SLS 说它的 Space 在 A 屏
        let spaces = FakeSpaces(
            entries: [SpaceEntry(spaceID: 11, displayUUID: displayA, index: 1, kind: 0)],
            byWindow: [1: 11])
        let snapshot = compose(composer(spaces: spaces),
                               [window(1, title: "stale-frame", x: 1100, y: 100, w: 400, h: 300)],
                               displays: [a, b])
        let w = try XCTUnwrap(snapshot.windows.first)
        XCTAssertEqual(w.displayUUID, displayA, "Space 所属屏优先于 frame 相交（后台窗 frame 过期会归错屏）")
        XCTAssertEqual(w.spaceIndex, 1)

        // 无 Space 归属 → 回落 frame 相交（保留原行为）
        let noSpace = compose(composer(spaces: nil),
                              [window(2, title: "frame-only", x: 1100, y: 100, w: 400, h: 300)],
                              displays: [a, b])
        XCTAssertEqual(noSpace.windows.first?.displayUUID, displayB, "无 Space 归属时按 frame 定屏")
    }

    /// spaceIndex 经 SpaceProviding 接缝；归一化几何按所属屏换算并夹取 [0,1]
    func testSpaceIndexViaSpaceProvidingAndNormalizedGeometry() throws {
        let a = fakeDisplay(displayA, x: 0, y: 0, w: 1000, h: 1000)
        let spaces = FakeSpaces(
            entries: [SpaceEntry(spaceID: 11, displayUUID: displayA, index: 2, kind: 0)],
            byWindow: [1: 11])
        let snapshot = compose(composer(spaces: spaces),
                               [window(1, title: "t", x: 100, y: 200, w: 400, h: 300)],
                               displays: [a])
        let w = try XCTUnwrap(snapshot.windows.first)
        XCTAssertEqual(w.spaceIndex, 2, "spaceIndex = SpaceEntry.index")
        XCTAssertEqual(w.x, 0.1); XCTAssertEqual(w.y, 0.2)
        XCTAssertEqual(w.w, 0.4); XCTAssertEqual(w.h, 0.3)
        XCTAssertEqual(snapshot.spaces.map(\.index), [2], "spaces 来自 managedSpaces")
        XCTAssertEqual(snapshot.spaces.map(\.kind), [.user])
    }

    /// 兄弟序：同应用同标题按归一化「先 y 后 x」（复用 ConservativeMatcher 同一规则）
    func testSiblingOrderIsYThenX() throws {
        let a = fakeDisplay(displayA)
        let spaces = FakeSpaces(entries: [SpaceEntry(spaceID: 11, displayUUID: displayA, index: 1, kind: 0)],
                                byWindow: [1: 11, 2: 11, 3: 11])
        let snapshot = compose(composer(spaces: spaces),
                               [window(1, title: "t", x: 800, y: 100),
                                window(2, title: "t", x: 100, y: 500),
                                window(3, title: "t", x: 100, y: 100)],
                               displays: [a])
        XCTAssertEqual(snapshot.windows.map(\.x), [0.1, 0.8, 0.1],
                       "输出序 = 兄弟序：先 y 后 x（同 y 取 x 小者）")
        XCTAssertEqual(snapshot.windows.map(\.siblingIndex), [0, 1, 2],
                       "排名：w3(0.1,0.1)=0、w1(0.8,0.1)=1、w2(0.1,0.5)=2")
    }

    /// 离屏候选读 AXMinimized；在屏最小整屏候选读 AXFullScreen：全屏不进 windows、bundleID 归全屏 Space
    func testFullscreenWindowExcludedAndAttributedToFullscreenSpace() throws {
        let a = fakeDisplay(displayA)
        let spaces = FakeSpaces(
            entries: [SpaceEntry(spaceID: 11, displayUUID: displayA, index: 1, kind: 0),
                      SpaceEntry(spaceID: 99, displayUUID: displayA, index: 2, kind: 4)],
            byWindow: [1: 11, 7: 99, 8: 99])
        let ax = FakeAXProber(minimizedIDs: [7], fullscreenIDs: [8])
        let composer = SnapshotComposer(spaces: spaces, ax: ax)
        let snapshot = compose(composer,
                               [window(7, title: "bg", x: 100, y: 100, onscreen: false),
                                window(8, title: "full", x: 0, y: 0, w: 1000, h: 1000)],
                               displays: [a])
        XCTAssertEqual(snapshot.windows.count, 1, "全屏窗口不进 windows（spec §7.3）")
        XCTAssertEqual(snapshot.windows.first?.minimized, true, "离屏候选经 AX 读 minimized")
        let fullscreenSpace = try XCTUnwrap(snapshot.spaces.first { $0.kind == .fullscreen })
        XCTAssertEqual(fullscreenSpace.fullscreenAppBundleID, "com.a", "全屏应用由 Space 携带")
        XCTAssertEqual(fullscreenSpace.index, 2)
    }

    /// frame==整屏但 AXFullScreen=false（手动铺满的普通窗）：照常进 windows
    func testManuallyMaximizedWindowStaysRegularWindow() throws {
        let a = fakeDisplay(displayA)
        let spaces = FakeSpaces(entries: [SpaceEntry(spaceID: 11, displayUUID: displayA, index: 1, kind: 0)],
                                byWindow: [1: 11])
        let snapshot = compose(composer(spaces: spaces),
                               [window(1, title: "big", x: 0, y: 0, w: 1000, h: 1000)],
                               displays: [a])
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.x, 0)
        XCTAssertEqual(snapshot.spaces.filter { $0.kind == .fullscreen }.count, 0)
    }

    /// Space 数据不可用 → 降级：spaces=[]、spaceIndex=1（几何层照常，spec §8.5）
    func testDegradedWithoutSpaceProvider() throws {
        let a = fakeDisplay(displayA)
        let snapshot = compose(composer(spaces: nil),
                               [window(1, title: "t", x: 100, y: 100)],
                               displays: [a])
        XCTAssertEqual(snapshot.spaces, [])
        XCTAssertEqual(snapshot.windows.first?.spaceIndex, 1)
    }

    /// 拓扑条目：UUID、整块 frame、旋转角；capturedAt 透传
    func testTopologyAndCapturedAt() throws {
        let a = fakeDisplay(displayA, x: 0, y: 0, w: 2560, h: 1440)
        let date = Date(timeIntervalSince1970: 100)
        let snapshot = compose(composer(spaces: nil), [], displays: [a], capturedAt: date)
        XCTAssertEqual(snapshot.capturedAt, date)
        let topo = try XCTUnwrap(snapshot.topology.first)
        XCTAssertEqual(topo.uuid, displayA)
        XCTAssertEqual(topo.frame.w, 2560); XCTAssertEqual(topo.frame.h, 1440)
        XCTAssertEqual(topo.orientation, 0)
        XCTAssertFalse(topo.localizedName.isEmpty, "localizedName 兜底非空")
        XCTAssertEqual(snapshot.version, snapshotSchemaVersion)
    }
}
