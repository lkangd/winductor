import CoreGraphics
import XCTest
@testable import Core

// LiveWindowSetTests — 实况窗口集合口径（票 dp-11；诊断 acceptance4 R1）。
// 接缝：LiveWindowSet.collect（快照组装、恢复实况收集、VerifyCLI 枚举共用这一份判定）。
final class LiveWindowSetTests: XCTestCase {
    private let displays = [
        Displays.Info(id: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), uuid: "A-uuid"),
    ]
    private let spaceA = SpaceEntry(spaceID: 10, displayUUID: "A-uuid", index: 1, kind: 0)

    private func sample(_ wid: UInt32, pid: Int32 = 1, onscreen: Bool = true,
                        appHidden: Bool = false) -> CGWindowSample {
        CGWindowSample(windowID: wid, pid: pid, bundleID: "com.t", title: "T",
                       bounds: CGRect(x: 100, y: 100, width: 400, height: 300),
                       isOnscreen: onscreen, appHidden: appHidden)
    }

    /// 调用记录：ordered-out 查询与 AX minimized 批量探测各收到哪些窗
    private final class Calls {
        var orderedQueries: [[UInt32]] = []
        var minimizedProbes: [[UInt32]] = []
    }

    private func collect(_ samples: [CGWindowSample], spaces: [UInt32: Int64]?,
                         orderedOut: Set<UInt32>? = [], minimized: Set<UInt32> = [],
                         calls: Calls = Calls()) -> [LiveWindowMember] {
        LiveWindowSet.collect(
            samples: samples, displays: displays, spaceIDByWindow: spaces, spaceEntries: [spaceA],
            orderedOut: { ids in calls.orderedQueries.append(ids); return orderedOut },
            minimized: { probed in
                calls.minimizedProbes.append(probed.map(\.windowID))
                return minimized.intersection(probed.map(\.windowID))
            })
    }

    /// 幽灵窗（实测 TextInputUI ×20 等）：SLS 无 Space 归属 → 不入集合；
    /// 多 Space 粘性窗由 SpaceAdapter.spaceIDsByWindowID 已不入表，同口径排除
    func testWindowWithoutSpaceAttributionIsExcluded() {
        let members = collect([sample(1), sample(2)], spaces: [1: spaceA.spaceID])
        XCTAssertEqual(members.map(\.window.sample.windowID), [1])
    }

    /// Space 数据整体不可用：维持降级（不按归属排除，frame 兜底定屏）
    func testSpaceDataUnavailableKeepsAllWindows() {
        let members = collect([sample(1), sample(2)], spaces: nil)
        XCTAssertEqual(members.map(\.window.sample.windowID), [1, 2])
        XCTAssertNil(members.first?.window.space)
    }

    /// 有 Space 归属的幽灵窗（实测 WeChat 隐藏 280×380「Weixin」、Chrome 气泡）：ordered out 且非最小化 → 排除；
    /// 最小化窗同样 ordered out（实测 Chrome 1920×993）→ 保留并记 minimized（L4）
    func testOrderedOutWindowIsExcludedUnlessMinimized() throws {
        let members = collect([sample(1), sample(2, onscreen: false), sample(3, onscreen: false)],
                              spaces: [1: 10, 2: 10, 3: 10], orderedOut: [2, 3], minimized: [3])
        XCTAssertEqual(members.map(\.window.sample.windowID), [1, 3])
        XCTAssertEqual(members.map(\.minimized), [false, true])
    }

    /// 应用被隐藏（⌘H）时其窗也可能 ordered out：按普通窗保留
    func testOrderedOutWindowOfHiddenAppIsKept() {
        let members = collect([sample(1, onscreen: false, appHidden: true)],
                              spaces: [1: 10], orderedOut: [1])
        XCTAssertEqual(members.map(\.window.sample.windowID), [1])
        XCTAssertEqual(members.first?.minimized, false)
    }

    /// 排列查询只问有 Space 归属的候选；AX 只对 ordered-out 候选批量探一次
    //（在其他 Space 的真窗 ordered in、不在屏也不探 AX）
    func testOrderingQueriedForCandidatesAndAXProbedOnlyForOrderedOut() {
        let calls = Calls()
        _ = collect([sample(1), sample(2, onscreen: false), sample(3, onscreen: false), sample(4)],
                    spaces: [1: 10, 2: 10, 3: 10], orderedOut: [3], calls: calls)
        XCTAssertEqual(calls.orderedQueries, [[1, 2, 3]])
        XCTAssertEqual(calls.minimizedProbes, [[3]])
    }

    /// 排列数据不可用（符号缺失/读失败）：不按排列排除，minimized 退回「不在屏才探」
    func testOrderingUnavailableFallsBackToOffscreenProbe() {
        let calls = Calls()
        let members = collect([sample(1), sample(2, onscreen: false)],
                              spaces: [1: 10, 2: 10], orderedOut: nil, minimized: [2], calls: calls)
        XCTAssertEqual(members.map(\.window.sample.windowID), [1, 2])
        XCTAssertEqual(members.map(\.minimized), [false, true])
        XCTAssertEqual(calls.minimizedProbes, [[2]])
    }

    /// 无需探测时不调 AX（在屏、ordered in 的常规场景零 AX）
    func testNoAXProbeWhenNothingOrderedOut() {
        let calls = Calls()
        _ = collect([sample(1), sample(2, onscreen: false)], spaces: [1: 10, 2: 10], orderedOut: [], calls: calls)
        XCTAssertEqual(calls.minimizedProbes, [])
    }
}
