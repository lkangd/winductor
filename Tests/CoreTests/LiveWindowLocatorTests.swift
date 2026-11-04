import CoreGraphics
import XCTest
@testable import Core

// LiveWindowLocatorTests — 屏归属 + 比例几何（GLOSSARY「屏归属」）。
// 接缝：LiveWindowLocator.locate（快照、恢复、验证器共用）。
final class LiveWindowLocatorTests: XCTestCase {
    /// 双屏：A (0,0,1000,1000)、B (2000,0,1000,500)
    private let displays = [
        Displays.Info(id: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), uuid: "A-uuid"),
        Displays.Info(id: 2, bounds: CGRect(x: 2000, y: 0, width: 1000, height: 500), uuid: "B-uuid"),
    ]
    private let spaceA = SpaceEntry(spaceID: 10, displayUUID: "A-uuid", index: 1, kind: 0)
    private let spaceB = SpaceEntry(spaceID: 20, displayUUID: "B-uuid", index: 1, kind: 0)

    private func sample(_ wid: UInt32, _ rect: CGRect, onscreen: Bool = true) -> CGWindowSample {
        CGWindowSample(windowID: wid, pid: 1, bundleID: "com.t", title: "T", bounds: rect, isOnscreen: onscreen)
    }

    private func locate(_ samples: [CGWindowSample], spaces: [UInt32: Int64] = [:]) -> [LocatedWindow] {
        LiveWindowLocator.locate(samples: samples, displays: displays,
                                 spaceIDByWindow: spaces, spaceEntries: [spaceA, spaceB])
    }

    /// 后台 Space 窗的 frame 是过期值（11-03 实测）：frame 落在 B，所属 Space 在 A → 归 A
    func testSpaceOwnershipBeatsStaleFrame() {
        let located = locate([sample(1, CGRect(x: 2100, y: 100, width: 400, height: 200), onscreen: false)],
                             spaces: [1: spaceA.spaceID])
        XCTAssertEqual(located.map(\.display.uuid), ["A-uuid"])
        XCTAssertEqual(located.first?.space, spaceA)
    }

    /// SLS 报的 Space 所属屏已不在当前拓扑（拔屏后 SLS 尚未跟上）：按 frame 兜底定屏，且不得带出
    /// 该陈旧 Space（否则快照会记成「兜底屏 UUID + 旧 Space 的 index」）
    func testSpaceOnAbsentDisplayIsDroppedWithFrameFallback() {
        let gone = SpaceEntry(spaceID: 30, displayUUID: "GONE-uuid", index: 3, kind: 0)
        let located = LiveWindowLocator.locate(
            samples: [sample(1, CGRect(x: 100, y: 100, width: 200, height: 200))],
            displays: displays, spaceIDByWindow: [1: 30], spaceEntries: [spaceA, spaceB, gone])
        XCTAssertEqual(located.map(\.display.uuid), ["A-uuid"])
        XCTAssertNil(located.first?.space)
    }

    /// 无 Space 归属：跨屏窗按 frame 交集面积最大者定屏（A 交 100×1000，B 交 400×500）
    func testWithoutSpaceLargestIntersectionWins() {
        let located = locate([sample(1, CGRect(x: 900, y: 0, width: 1500, height: 1000))])
        XCTAssertEqual(located.map(\.display.uuid), ["B-uuid"])
        XCTAssertNil(located.first?.space)
    }

    /// 完全屏外（落在 A、B 之间的缝里）：取中心距离最近的屏（窗中心 (1750,50)：距 B 中心更近）
    func testOffscreenFallsBackToNearestCenter() {
        let located = locate([sample(1, CGRect(x: 1600, y: 0, width: 300, height: 100))])
        XCTAssertEqual(located.map(\.display.uuid), ["B-uuid"])
    }

    /// 比例几何在归属屏整块 bounds 上归一并夹 [0,1]（快照值是夹过的，比对两侧须同口径）：
    /// A 上窗 (-100,250,500,1200) → x 夹 0、y 0.25、w 0.5、h 夹 1
    func testRatioIsClampedToUnitRange() {
        let located = locate([sample(1, CGRect(x: -100, y: 250, width: 500, height: 1200))],
                             spaces: [1: spaceA.spaceID])
        let w = try? XCTUnwrap(located.first)
        XCTAssertEqual(w?.x, 0); XCTAssertEqual(w?.y, 0.25)
        XCTAssertEqual(w?.w, 0.5); XCTAssertEqual(w?.h, 1)
    }

    /// 在 B（1000×500）上按 B 的 bounds 归一：(2250,100,500,250) → (0.25,0.2,0.5,0.5)
    func testRatioUsesOwningDisplayBounds() {
        let located = locate([sample(1, CGRect(x: 2250, y: 100, width: 500, height: 250))],
                             spaces: [1: spaceB.spaceID])
        let w = try? XCTUnwrap(located.first)
        XCTAssertEqual(w?.x, 0.25); XCTAssertEqual(w?.y, 0.2)
        XCTAssertEqual(w?.w, 0.5); XCTAssertEqual(w?.h, 0.5)
    }

    /// 归属屏取不到稳定 UUID（nil/空）或尺寸为 0：无从记录比对，丢弃该窗（不写空 UUID）
    func testDropsWindowWhenOwningDisplayUnusable() {
        let unusable = [
            Displays.Info(id: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), uuid: nil),
            Displays.Info(id: 2, bounds: CGRect(x: 2000, y: 0, width: 1000, height: 1000), uuid: ""),
            Displays.Info(id: 3, bounds: CGRect(x: 4000, y: 0, width: 0, height: 0), uuid: "Z-uuid"),
        ]
        let located = LiveWindowLocator.locate(
            samples: [sample(1, CGRect(x: 100, y: 100, width: 200, height: 200)),
                      sample(2, CGRect(x: 2100, y: 100, width: 200, height: 200)),
                      sample(3, CGRect(x: 4000, y: 0, width: 200, height: 200))],
            displays: unusable, spaceIDByWindow: [3: 30],
            spaceEntries: [SpaceEntry(spaceID: 30, displayUUID: "Z-uuid", index: 1, kind: 0)])
        XCTAssertEqual(located, [])
    }
}
