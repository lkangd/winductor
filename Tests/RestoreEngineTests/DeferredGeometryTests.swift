import AppKit
@testable import Core
import CoreGraphics
import Foundation
@testable import RestoreEngine
import SnapshotEngine
import XCTest

// DeferredGeometryTests — 延迟几何模块（记录 → 覆盖 → 可见即补写）。
// 接缝：DeferredGeometry 公共接口（replacePending / geometryOverrides / tick / start·stop），
// 注入 FakeBridge（活跃 Space、窗归属）+ FakeGeometry（AX 写）。
final class DeferredGeometryTests: XCTestCase {
    private let entry = PendingGeometryEntry(windowID: 7, displayUUID: "A-uuid", x: 0.1, y: 0.2, w: 0.5, h: 0.4)

    private func makeModule(bridge: FakeBridge, geometry: FakeGeometry = FakeGeometry(),
                            session: SkyLightSession = SkyLightSession()) throws -> DeferredGeometry {
        DeferredGeometry(directory: try makeTempDir(), spaces: bridge, session: session,
                         writer: geometry, displaysProvider: { World.displays() },
                         frameReader: { _ in nil })
    }

    /// 补写前快照按 pending 目标记录（防 macOS 中间态被固化成下次恢复目标，11-03 ghostty/WeCom）
    func testRecordedPendingBecomesSnapshotOverride() throws {
        let module = try makeModule(bridge: FakeBridge(entries: [], byWindow: [:]))
        XCTAssertEqual(module.geometryOverrides(), [:])
        module.replacePending([entry])
        XCTAssertEqual(module.geometryOverrides(),
                       [7: WindowGeometryOverride(displayUUID: "A-uuid", x: 0.1, y: 0.2, w: 0.5, h: 0.4)])
    }

    /// 一轮消费：窗所在 Space 是某屏活跃 Space = 用户看得见 = AX 可写 → 补写并消费；其余保留
    func testTickAppliesOnlyWindowsOnActiveSpaces() throws {
        let bridge = FakeBridge(entries: [], byWindow: [7: 5, 8: 99])
        bridge.activeSpaces = [5]
        let geometry = FakeGeometry()
        let module = try makeModule(bridge: bridge, geometry: geometry)
        let other = PendingGeometryEntry(windowID: 8, displayUUID: "A-uuid", x: 0, y: 0, w: 1, h: 1)
        module.replacePending([entry, other])

        module.tick()

        XCTAssertEqual(geometry.calls, [FakeGeometry.Call(windowID: 7, position: CGPoint(x: 100, y: 200),
                                                          size: CGSize(width: 500, height: 400))])
        XCTAssertEqual(Array(module.geometryOverrides().keys), [8], "已补写的窗不再覆盖快照")
    }

    /// 恢复管线独占期间不消费（管线自己在摆窗，补写会与之争 AX）
    func testTickSkippedWhilePipelineExclusive() throws {
        let bridge = FakeBridge(entries: [], byWindow: [7: 5])
        bridge.activeSpaces = [5]
        let geometry = FakeGeometry(), session = SkyLightSession()
        let module = try makeModule(bridge: bridge, geometry: geometry, session: session)
        module.replacePending([entry])

        session.exclusive("restore") { module.tick() }

        XCTAssertTrue(geometry.calls.isEmpty)
        XCTAssertEqual(Array(module.geometryOverrides().keys), [7])
    }

    /// 补写 AX 写阻塞超过排空上限，管线照常开工并写下目标：旧补写迟到返回记 stale、不消费不计失败；
    /// 管线为该窗补记 pending，下一轮补写重写管线目标 ⇒ 最终几何 = 管线结果（不跳回旧 pending）
    func testPipelineGeometryWinsOverDeferredApplyStillInFlightAfterDrainTimeout() throws {
        try assertPipelineGeometryWinsOverStaleDeferredApply(oldWriteReturnsDuringPipelineWrite: false)
    }

    /// 旧补写在管线 L1 写之后落地、并在 L1 写返回前已注销在途：管线须在写前就认出在途
    func testPipelineGeometryWinsWhenStaleDeferredApplyFinishesDuringPipelineWrite() throws {
        try assertPipelineGeometryWinsOverStaleDeferredApply(oldWriteReturnsDuringPipelineWrite: true)
    }

    private func assertPipelineGeometryWinsOverStaleDeferredApply(oldWriteReturnsDuringPipelineWrite: Bool) throws {
        let session = SkyLightSession(drainTimeout: 0.1)
        let bridge = FakeBridge(entries: [World.entry("A-uuid", index: 1, id: 5), World.entry("B-uuid", index: 1, id: 6)],
                                byWindow: [101: 5])
        bridge.activeSpaces = [5]
        let deferredWriter = FakeGeometry(), pipelineWriter = FakeGeometry(), log = LogSpy()
        let applyEntered = DispatchSemaphore(value: 0), releaseApply = DispatchSemaphore(value: 0)
        deferredWriter.onApply = { applyEntered.signal(); releaseApply.wait() }
        let dir = try makeTempDir()
        let module = DeferredGeometry(directory: dir, spaces: bridge, session: session, writer: deferredWriter,
                                      displaysProvider: { World.displays() }, log: log, frameReader: { _ in nil })
        module.replacePending([PendingGeometryEntry(windowID: 101, displayUUID: "A-uuid", x: 0.5, y: 0.5, w: 0.2, h: 0.2)])

        let staleTickDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { module.tick(); staleTickDone.signal() }
        applyEntered.wait()
        if oldWriteReturnsDuringPipelineWrite {
            pipelineWriter.onApply = { releaseApply.signal(); staleTickDone.wait() }
        }

        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [World.topologyEntry(uuid: "A-uuid", name: "A", orientation: 0, x: 0, y: 0, w: 1000, h: 1000),
                       World.topologyEntry(uuid: "B-uuid", name: "B", orientation: 0, x: 2000, y: 0, w: 1000, h: 1000)],
            spaces: [World.userSpace("A-uuid", index: 1), World.userSpace("B-uuid", index: 1)],
            windows: [World.snapshotWindow(bundleID: "com.t.a", title: "Doc", sibling: 0,
                                           display: "A-uuid", space: 1, x: 0.1, y: 0.1, w: 0.4, h: 0.4)])
        let engine = RestoreEngine(
            store: PresetStore(directory: dir),
            spaces: bridge,
            enumerator: FakeEnumerator([World.sample(wid: 101, bundleID: "com.t.a", title: "Doc",
                                                     displayOrigin: .zero, displaySize: CGSize(width: 1000, height: 1000),
                                                     x: 0.3, y: 0.3, w: 0.4, h: 0.4)]),
            ax: FakeAX(), geometry: pipelineWriter, session: session, deferredGeometry: module,
            displaysProvider: { World.displays() }, rotationProvider: World.rotationProvider([:]), log: log)
        _ = try engine.restore(snapshot: snapshot)

        let target = FakeGeometry.Call(windowID: 101, position: CGPoint(x: 100, y: 100), size: CGSize(width: 400, height: 400))
        XCTAssertEqual(pipelineWriter.calls, [target], "排空超时后管线照常写目标")

        if !oldWriteReturnsDuringPipelineWrite {
            releaseApply.signal()
            XCTAssertEqual(staleTickDone.wait(timeout: .now() + 2), .success)
        }
        XCTAssertTrue(log.all.contains("[restore] deferred wid=101 result=stale detail=pipeline-started-during-apply"),
                      "实际：\(log.all)")
        XCTAssertEqual(module.geometryOverrides()[101],
                       WindowGeometryOverride(displayUUID: "A-uuid", x: 0.1, y: 0.1, w: 0.4, h: 0.4),
                       "管线为在途窗补记本轮目标，旧补写不得消费它")

        deferredWriter.onApply = nil
        module.tick()
        XCTAssertEqual(deferredWriter.calls.last, target, "下一轮补写重写管线目标，盖过迟到的旧写")
        XCTAssertNil(module.geometryOverrides()[101])
    }

    /// 自驱：start 后 Space 切换即补一轮（后台窗正是在用户切过去时才可写，不等下一个 2s tick）；
    /// stop 后断环释放（11-03 实测缺陷：消费器曾因 [weak self] 随装配函数返回被释放，pending 从未消费）
    func testStartedModuleConsumesOnSpaceChangeAndReleasesAfterStop() throws {
        let bridge = FakeBridge(entries: [], byWindow: [7: 5])
        bridge.activeSpaces = [5]
        let geometry = FakeGeometry()
        let center = NotificationCenter()
        weak var weakModule: DeferredGeometry?
        do {
            let module = try makeModule(bridge: bridge, geometry: geometry)
            module.replacePending([entry])
            module.start(interval: 60, center: center)
            weakModule = module
        }
        XCTAssertNotNil(weakModule, "启动后自持存活，直到 stop")

        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        let applied = expectation(description: "applied")
        DispatchQueue.global().async {
            while geometry.calls.isEmpty { Thread.sleep(forTimeInterval: 0.02) }
            applied.fulfill()
        }
        wait(for: [applied], timeout: 3)

        weakModule?.stop()
        let released = expectation(description: "released")
        DispatchQueue.global().async {
            while weakModule != nil { Thread.sleep(forTimeInterval: 0.02) }
            released.fulfill()
        }
        wait(for: [released], timeout: 2)
    }
}
