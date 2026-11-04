@testable import Core
@testable import RestoreEngine
import CoreGraphics
import Foundation
import XCTest

// ReturnHomeLedgerTests — 冻结点账本（拔屏冻结拔屏前快照、插回时选恢复源 / 拦中间态）。
// 接缝：ReturnHomeLedger（真实 SnapshotStore 落临时目录）。事件时序/防抖/日志由 TriggerChainTests 端到端覆盖。
final class ReturnHomeLedgerTests: XCTestCase {
    private let a = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let b = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    private let c = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
    private var store: SnapshotStore!

    override func setUpWithError() throws {
        store = SnapshotStore(directory: try makeTempDir())
    }

    private func snap(_ uuids: [String], _ bundle: String) -> Snapshot {
        Snapshot(capturedAt: Date(timeIntervalSince1970: 1),
                 topology: uuids.map { World.topologyEntry(uuid: $0, name: $0, orientation: 0, x: 0, y: 0, w: 1000, h: 1000) },
                 spaces: [],
                 windows: [SnapshotWindow(bundleID: bundle, title: "t", siblingIndex: 0, displayUUID: uuids[0],
                                          spaceIndex: 1, x: 0, y: 0, w: 0.5, h: 0.5, minimized: false)])
    }

    @discardableResult
    private func writeLive(_ uuids: [String], _ bundle: String) throws -> Snapshot {
        let s = snap(uuids, bundle)
        try store.write(s, topologyKey: SnapshotStore.topologyKey(forDisplayUUIDs: uuids))
        return s
    }

    func testNoHomesLeavesReturnUnguarded() {
        var ledger = ReturnHomeLedger(store: store)
        XCTAssertEqual(ledger.returnTo([a, b]), .unguarded)
    }

    /// 拔屏冻结拔屏前快照；插回中间拓扑不放行；回到该拓扑用冻结内容（不读 poller 已重写的 live）
    func testUnplugFreezesHomeAndReturnUsesHeldContent() throws {
        let held = try writeLive([a, b, c], "held.app")
        var ledger = ReturnHomeLedger(store: store)
        ledger.settle(baseline: [a, b, c])
        XCTAssertEqual(ledger.unplugged(from: [a, b, c]), held)
        try writeLive([a, b, c], "polluted.app")

        XCTAssertEqual(ledger.returnTo([a, c]), .intermediate(homeDisplays: 3), "中间拓扑：不自动恢复")
        XCTAssertEqual(ledger.returnTo([a, b, c]), .home(held), "回到冻结拓扑：用冻结内容")
        XCTAssertEqual(ledger.returnTo([a, b, c]), .unguarded, "回归后冻结点作废（下次拔屏重新冻结）")
    }

    /// 多段拔屏 3→2→1 每段各冻结一份；回到 3 屏用最外层冻结内容，被回归覆盖的内层冻结点一并作废
    func testMultiStageUnplugKeepsOuterHome() throws {
        let outer = try writeLive([a, b, c], "outer.app")
        try writeLive([a, b], "inner.app")
        var ledger = ReturnHomeLedger(store: store)
        ledger.settle(baseline: [a, b, c])
        ledger.unplugged(from: [a, b, c])
        ledger.settle(baseline: [a, b])
        ledger.unplugged(from: [a, b])

        XCTAssertEqual(ledger.returnTo([a, b, c]), .home(outer))
        XCTAssertEqual(ledger.returnTo([a, b]), .unguarded, "⊆ 本次回归集合的冻结点已作废")
    }

    /// 插回冻结点的超集（如 2 屏下启动后接第 3 屏）：放行，恢复源回退现存拓扑匹配
    func testReturnToSupersetOfHomePasses() throws {
        try writeLive([a, b], "two.app")
        var ledger = ReturnHomeLedger(store: store)
        ledger.settle(baseline: [a, b])
        ledger.unplugged(from: [a, b])

        XCTAssertEqual(ledger.returnTo([a, b, c]), .supersetOfHome(homeDisplays: 2))
        XCTAssertEqual(ledger.returnTo([a, b, c]), .unguarded, "被超集取代的冻结点作废")
    }

    /// 冻结源取事件串首个事件时的 live（实测 11-03 09:08：拔屏开始后在途写盘把中途态落进 live，
    /// settle 时现读冻结了垃圾）；settle 时基线已不是起点集合则不用它
    func testFreezeUsesLiveAsOfBurstStart() throws {
        let before = try writeLive([a, b, c], "before.app")
        var ledger = ReturnHomeLedger(store: store)
        ledger.burstStarted(baseline: [a, b, c])
        try writeLive([a, b, c], "mid-unplug.app")
        ledger.settle(baseline: [a, b, c])
        XCTAssertEqual(ledger.unplugged(from: [a, b, c]), before)

        let current = try writeLive([a, b], "two.app")
        ledger.burstStarted(baseline: [a, b, c])
        ledger.settle(baseline: [a, b])
        XCTAssertEqual(ledger.unplugged(from: [a, b]), current, "起点集合 ≠ settle 基线：现读")
    }

    /// 快速拔→插回（同处防抖静默期）：该拓扑已有冻结点则保留更早的拔屏前内容，不现读覆盖
    func testFastReplugKeepsExistingHome() throws {
        let original = try writeLive([a, b], "original.app")
        var ledger = ReturnHomeLedger(store: store)
        ledger.settle(baseline: [a, b])
        ledger.unplugged(from: [a, b])
        try writeLive([a, b], "later.app")

        ledger.settle(baseline: [a, b])
        XCTAssertEqual(ledger.fastReplugged(to: [a, b]), .alreadyHeld)
        XCTAssertEqual(ledger.returnTo([a, b]), .home(original))

        let fresh = try writeLive([a, b], "fresh.app")
        ledger.settle(baseline: [a, b])
        XCTAssertEqual(ledger.fastReplugged(to: [a, b]), .frozen(fresh), "无冻结点：补记")
    }

    /// 少屏状态下启动（实测事故 11-03 07:39）：按磁盘上「当前集合的极大超集拓扑」重建冻结点——
    /// 当前缺屏 ⇒ 这些拓扑自拔屏后不可能被写过 = 拔屏前内容；非极大超集（{A,C} ⊂ {A,B,C}）视为中间拓扑
    func testLaunchSeedsHomesFromMaximalKnownSupersets() throws {
        let home = try writeLive([a, b, c], "home.app")
        try writeLive([a, c], "stale.app")
        try writeLive([a], "single.app")
        var ledger = ReturnHomeLedger(store: store)

        let seeded = ledger.seedAtLaunch(current: [a])

        XCTAssertEqual(seeded.map(\.uuids), [[a, b, c]])
        XCTAssertEqual(seeded.map(\.held), [home])
        XCTAssertEqual(ledger.returnTo([a, c]), .intermediate(homeDisplays: 3))
        XCTAssertEqual(ledger.returnTo([a, b, c]), .home(home))
    }
}
