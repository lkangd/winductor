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
                 spaces: [UInt32: SpaceEntry] = [101: World.entry("A-uuid", index: 1, id: 5)],
                 liveSpaces: [SpaceEntry] = [World.entry("A-uuid", index: 1, id: 5),
                                             World.entry("A-uuid", index: 2, id: 6),
                                             World.entry("B-uuid", index: 1, id: 7)]) -> [VerifyEntryResult] {
        VerifyComparer.compare(snapshot: snapshot, liveWindows: live,
                               displayUUIDByWindowID: displays, spaceEntryByWindowID: spaces,
                               liveSpaces: liveSpaces)
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
            spaces: [101: World.entry("B-uuid", index: 1, id: 7)])[0].verdict else {
            return XCTFail("应判 FAIL")
        }
        // 期望 Space 是 A 屏的桌面（按 Space 身份比，票 15）：落在 B 屏 #1 同时不符屏与 Space
        XCTAssertEqual(reasons, ["display", "space"])
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

    /// 标题变了（如文档改名）但几何兜底配上：照常核验，并标出经兜底配对（verify 报告据此注明新旧标题）
    func testGeometryFallbackMatchIsFlagged() throws {
        let live = [LiveWindow(cgWindowID: 101, bundleID: "com.t.a", title: "Doc (edited)",
                               x: 0.1, y: 0.1, w: 0.4, h: 0.4, minimized: false)]
        let results = compare(live: live)
        XCTAssertEqual(results[0].verdict, .pass)
        XCTAssertEqual(results[0].viaGeometryFallback, true)

        let exact = compare(live: [LiveWindow(cgWindowID: 101, bundleID: "com.t.a", title: "Doc",
                                              x: 0.1, y: 0.1, w: 0.4, h: 0.4, minimized: false)])
        XCTAssertEqual(exact[0].viaGeometryFallback, false)
    }

    // MARK: display-presets 票 15 — Space 比对与恢复落位同口径（同屏用户桌面序号映射，Core 共用一份）

    /// 单屏 A：快照 [u,u,FS,FS] 窗在 #2；实况 [u,FS,FS,u]（用户把全屏 Space 挪到前面）
    func reorderedCompare(liveSpaceIndexOfWindow index: Int) -> VerifyEntryResult {
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000)],
            spaces: [World.userSpace("A-uuid", index: 1), World.userSpace("A-uuid", index: 2),
                     SnapshotSpace(displayUUID: "A-uuid", index: 3, kind: .fullscreen, fullscreenAppBundleID: "com.t.fs1"),
                     SnapshotSpace(displayUUID: "A-uuid", index: 4, kind: .fullscreen, fullscreenAppBundleID: "com.t.fs2")],
            windows: [World.snapshotWindow(bundleID: "com.t.chat", title: "Chat", sibling: 0,
                                           display: "A-uuid", space: 2, x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        let liveSpaces = [World.entry("A-uuid", index: 1, id: 11),
                          World.entry("A-uuid", index: 2, id: 12, kind: SpaceKind.fullscreen),
                          World.entry("A-uuid", index: 3, id: 13, kind: SpaceKind.fullscreen),
                          World.entry("A-uuid", index: 4, id: 14)]
        let live = [LiveWindow(cgWindowID: 101, bundleID: "com.t.chat", title: "Chat",
                               x: 0.1, y: 0.1, w: 0.4, h: 0.4, minimized: false)]
        return VerifyComparer.compare(snapshot: snapshot, liveWindows: live,
                                      displayUUIDByWindowID: [101: "A-uuid"],
                                      spaceEntryByWindowID: [101: liveSpaces[index - 1]],
                                      liveSpaces: liveSpaces)[0]
    }

    func testReorderedSpacesWindowOnMappedUserDesktopPasses() throws {
        // 快照第 2 个用户桌面 → 实况第 2 个用户桌面 #4：恢复落在这里，verify 须判通过
        let result = reorderedCompare(liveSpaceIndexOfWindow: 4)
        XCTAssertEqual(result.verdict, .pass)
        XCTAssertEqual(result.spaceMatched, true)
        XCTAssertEqual(result.expectedSpaceIndex, 4)
    }

    func testReorderedSpacesWindowOnSameAbsoluteIndexFails() throws {
        // 同绝对 index #2 在实况是全屏 Space：不是恢复目标 → space 失败
        let result = reorderedCompare(liveSpaceIndexOfWindow: 2)
        XCTAssertEqual(result.verdict, .fail(reasons: ["space"]))
        XCTAssertEqual(result.spaceMatched, false)
        XCTAssertEqual(result.expectedSpaceIndex, 4)
    }
}
