@testable import Core
import RestoreEngine
import XCTest

// VerifyComparer 单测 — verify 全量比对核心（spec §9.1，票 14）。
// 预期 SKIP 集推导与恢复管线共用同一份 Core.ConservativeMatcher（08 #1）；
// PASS = 几何精确 + 屏幕归属 + Space 归属全比对通过（数据缺失的维度不阻断，标注未比对）。

final class VerifyComparerTests: XCTestCase {
    let snapshot = Snapshot(
        capturedAt: Date(),
        topology: [
            World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000),
            World.topologyEntry(uuid: "B-uuid", name: "B", orientation: 0, x: 2000, y: 0, w: 1000, h: 1000),
        ],
        spaces: [World.userSpace("A-uuid", index: 1), World.userSpace("B-uuid", index: 1)],
        windows: [
            World.snapshotWindow(bundleID: "com.t.a", title: "Doc", sibling: 0,
                                 display: "A-uuid", space: 1, x: 0.1, y: 0.1, w: 0.4, h: 0.4),
            World.snapshotWindow(bundleID: "com.t.gone", title: "Gone", sibling: 0,
                                 display: "B-uuid", space: 1, x: 0.1, y: 0.1, w: 0.2, h: 0.2),
        ])

    func compare(live: [LiveWindow],
                 displays: [UInt32: String] = [101: "A-uuid"],
                 spaces: [UInt32: SpaceEntry] = [101: World.entry("A-uuid", index: 1, id: 5)]) -> [VerifyEntryResult] {
        VerifyComparer.compare(snapshot: snapshot, liveWindows: live,
                               displayUUIDByWindowID: displays, spaceEntryByWindowID: spaces)
    }

    func testAllDimensionsEqualPasses() throws {
        let live = [LiveWindow(cgWindowID: 101, bundleID: "com.t.a", title: "Doc",
                               x: 0.1, y: 0.1, w: 0.4, h: 0.4, minimized: false)]
        let results = compare(live: live)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].verdict, .pass)
        XCTAssertEqual(results[0].liveWindowID, 101)
        XCTAssertEqual(results[0].displayMatched, true)
        XCTAssertEqual(results[0].spaceMatched, true)
        XCTAssertEqual(results[0].geometryDelta ?? 1, 0, accuracy: 1e-9)
        // 快照外应用（com.t.gone 未运行）→ SKIP 推导 reason=app-not-running
        XCTAssertEqual(results[1].verdict, .skip(reason: "app-not-running"))
    }

    func testGeometryMismatchFails() throws {
        let live = [LiveWindow(cgWindowID: 101, bundleID: "com.t.a", title: "Doc",
                               x: 0.2, y: 0.1, w: 0.4, h: 0.4, minimized: false)]
        guard case .fail(let reasons) = compare(live: live)[0].verdict else {
            return XCTFail("应判 FAIL")
        }
        XCTAssertEqual(reasons, ["geometry"])
    }

    func testSpaceAttributionMismatchFails() throws {
        let live = [LiveWindow(cgWindowID: 101, bundleID: "com.t.a", title: "Doc",
                               x: 0.1, y: 0.1, w: 0.4, h: 0.4, minimized: false)]
        guard case .fail(let reasons) = compare(
            live: live,
            spaces: [101: World.entry("A-uuid", index: 2, id: 6)])[0].verdict else {
            return XCTFail("应判 FAIL")
        }
        XCTAssertEqual(reasons, ["space"])
    }

    func testDisplayAttributionMismatchFails() throws {
        let live = [LiveWindow(cgWindowID: 101, bundleID: "com.t.a", title: "Doc",
                               x: 0.1, y: 0.1, w: 0.4, h: 0.4, minimized: false)]
        guard case .fail(let reasons) = compare(
            live: live, displays: [101: "B-uuid"],
            spaces: [101: World.entry("B-uuid", index: 1, id: 6)])[0].verdict else {
            return XCTFail("应判 FAIL")
        }
        XCTAssertEqual(reasons, ["display"])
    }

    func testMissingSpaceDataDoesNotBlockPass() throws {
        // Space 数据不可用（降级）：该维度未比对不阻断 PASS（雏形口径，spec §8.5 降级阶梯）
        let live = [LiveWindow(cgWindowID: 101, bundleID: "com.t.a", title: "Doc",
                               x: 0.1, y: 0.1, w: 0.4, h: 0.4, minimized: false)]
        let results = compare(live: live, spaces: [:])
        XCTAssertEqual(results[0].verdict, .pass)
        XCTAssertNil(results[0].spaceMatched)
    }

    func testUnmatchedSameAppSkipsWithUnmatchedReason() throws {
        // 同应用在跑但标题/几何都配不上 → SKIP reason=unmatched（预期跳过集推导）
        let live = [LiveWindow(cgWindowID: 101, bundleID: "com.t.a", title: "New Tab",
                               x: 0.9, y: 0.9, w: 0.4, h: 0.4, minimized: false)]
        let results = compare(live: live)
        XCTAssertEqual(results[0].verdict, .skip(reason: "unmatched"))
        XCTAssertEqual(results[1].verdict, .skip(reason: "app-not-running"))
    }
}
