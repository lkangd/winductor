import Foundation
import SpaceAdapter
import XCTest
@testable import Core
@testable import MenubarKit
@testable import RestoreEngine

final class LastRestoreUndoTests: XCTestCase {
    private var performer: TestUndoPerformer!
    private var notifier: TestNotificationRecorder!
    private var ready = true
    private var refreshes = 0
    private var queued: [@Sendable () -> Void] = []

    override func setUp() {
        performer = TestUndoPerformer(canUndo: true)
        notifier = TestNotificationRecorder()
        ready = true
        refreshes = 0
        queued = []
    }

    private func makeUndo(queuedExecution: Bool = false) -> LastRestoreUndo {
        LastRestoreUndo(performer: performer,
                        readiness: { [unowned self] in ready },
                        enqueue: { [unowned self] work in
                            if queuedExecution { queued.append(work) } else { work() }
                        },
                        notifier: notifier,
                        refresh: { [unowned self] in refreshes += 1 })
    }

    func testAvailabilityIsLiveAndShortCircuitsWhenNotReady() {
        let undo = makeUndo()
        ready = false
        XCTAssertFalse(undo.isAvailable())
        XCTAssertEqual(performer.availabilityReads, 0)
        ready = true
        XCTAssertTrue(undo.isAvailable())
        performer.canUndoValue = false
        XCTAssertFalse(undo.isAvailable())
        XCTAssertEqual(performer.availabilityReads, 2, "不缓存可用性")
    }

    func testConditionalRequestRechecksAvailabilityButAttemptDoesNot() {
        let undo = makeUndo()
        XCTAssertTrue(undo.isAvailable())
        performer.canUndoValue = false
        performer.outcome = .failure(RestoreEngineError.undoSnapshotMissing)

        undo.requestIfAvailable()
        XCTAssertEqual(performer.undoCalls, 0)
        XCTAssertEqual(refreshes, 0)
        XCTAssertTrue(notifier.deliveries.isEmpty)
        let reads = performer.availabilityReads

        undo.request()
        XCTAssertEqual(performer.availabilityReads, reads, "旧菜单与恢复告知不新增可用性探测")
        XCTAssertEqual(performer.undoCalls, 1)
        XCTAssertEqual(notifier.deliveries.last?.body, "撤销失败：无可用回滚快照")
        XCTAssertEqual(refreshes, 1)
    }

    func testConditionalRequestUsesTheSameExecutionAndNotificationFlow() {
        let undo = makeUndo()
        undo.requestIfAvailable()
        XCTAssertEqual(performer.availabilityReads, 1)
        XCTAssertEqual(performer.undoCalls, 1)
        XCTAssertEqual(notifier.deliveries.last?.body, "撤销完成：5 窗口归位、0 跳过、0 失败")
        XCTAssertEqual(refreshes, 1)
    }

    func testNotReadyBeforeEnqueueIsSilentAndCanRecover() {
        let undo = makeUndo(queuedExecution: true)
        ready = false
        undo.request()
        XCTAssertTrue(queued.isEmpty)
        XCTAssertEqual(refreshes, 0)
        XCTAssertTrue(notifier.deliveries.isEmpty)
        ready = true
        undo.request()
        XCTAssertEqual(queued.count, 1)
        queued.removeFirst()()
        XCTAssertEqual(performer.undoCalls, 1)
    }

    func testNotReadyBeforeExecutionIsSilentWithoutRefresh() {
        let undo = makeUndo(queuedExecution: true)
        undo.request()
        ready = false
        queued.removeFirst()()
        XCTAssertEqual(performer.undoCalls, 0)
        XCTAssertTrue(notifier.deliveries.isEmpty)
        XCTAssertEqual(refreshes, 0, "权限拒绝不走完成刷新")
    }

    func testRepeatedRequestsAreNotCoalesced() {
        let undo = makeUndo(queuedExecution: true)
        undo.request()
        undo.request()
        XCTAssertEqual(queued.count, 2)
        queued.removeFirst()()
        queued.removeFirst()()
        XCTAssertEqual(performer.undoCalls, 2)
        XCTAssertEqual(refreshes, 2)
    }

    func testTwoStageUndoUsesVerbatimNotification() {
        performer.outcome = .success(UndoReport(
            okCount: 4, skipCount: 2, failCount: 0, matchedCount: 4, untouchedLiveCount: 0,
            undoSnapshotURL: URL(fileURLWithPath: "/tmp/undo.json"), fullscreenPendingCount: 2))
        let undo = makeUndo()
        undo.request()
        XCTAssertEqual(notifier.deliveries.first?.title, "撤销完成")
        XCTAssertEqual(notifier.deliveries.first?.body,
                       "撤销完成。2 个全屏应用无法在后台退出全屏：请在对应屏幕按 Esc 退出全屏，然后再次点击「撤销上次恢复」完成剩余归位。")
        XCTAssertEqual(refreshes, 1)
    }

    private struct OtherFailure: Error, CustomStringConvertible {
        var description: String { "test-failure" }
    }

    func testEveryFailurePreservesNotificationAndRefreshOrder() {
        let cases: [(Error, String)] = [
            (RestoreEngineError.undoSnapshotMissing, "撤销失败：无可用回滚快照"),
            (RestoreEngineError.undoSnapshotCorrupt("bad-json"), "撤销失败：回滚快照不可用（已按 §7.4 隔离，下次恢复重写）"),
            (RestoreEngineError.noActiveDisplay, "撤销失败：无活动显示器"),
            (OtherFailure(), "撤销失败：test-failure"),
        ]
        for (error, body) in cases {
            var events: [String] = []
            performer.outcome = .failure(error)
            notifier.onDelivery = { title, message in
                XCTAssertEqual(title, "撤销失败")
                XCTAssertEqual(message, body)
                events.append("notify")
            }
            let undo = LastRestoreUndo(performer: performer, readiness: { true }, enqueue: { $0() },
                                       notifier: notifier, refresh: { events.append("refresh") })
            undo.request()
            XCTAssertEqual(events, ["notify", "refresh"], "先通知，再刷新")
        }
    }

    func testBackgroundExecutionRefreshesOnMainAfterNotification() {
        let notified = expectation(description: "后台通知")
        let refreshed = expectation(description: "主线程刷新")
        performer.onUndo = { XCTAssertFalse(Thread.isMainThread) }
        notifier.onDelivery = { _, _ in
            XCTAssertFalse(Thread.isMainThread)
            notified.fulfill()
        }
        let recorder = notifier!
        let undo = LastRestoreUndo(performer: performer, readiness: { true }, notifier: recorder,
                                   refresh: {
                                       XCTAssertTrue(Thread.isMainThread)
                                       XCTAssertEqual(recorder.deliveries.count, 1)
                                       refreshed.fulfill()
                                   })
        undo.request()
        wait(for: [notified, refreshed], timeout: 3, enforceOrder: true)
        withExtendedLifetime(undo) {}
    }

    private struct UnusedSpaces: SpaceBridge {
        func managedSpaces() throws -> [SpaceEntry] { [] }
        func spaceIDsByWindowID() throws -> [UInt32: Int64] { [:] }
        func isLayerAvailable(_ layer: SpaceLayer) -> Bool { false }
        func moveWindowsToSpace(windowIDs: [UInt32], spaceID: Int64) throws -> Bool { false }
        func tryMoveMinimized(windowIDs: [UInt32], spaceID: Int64) throws -> Set<UInt32> { [] }
        func activeSpaceIDs() throws -> Set<Int64> { [] }
        func beginRestoreRound() {}
    }

    func testAvailabilityUsesRealUndoSnapshotWithoutCachingOrQuarantining() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("winductor-undo-availability-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PresetStore(directory: directory)
        let displays = [Displays.Info(id: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800), uuid: "A")]
        let engine = RestoreEngine(store: store, spaces: UnusedSpaces(), displaysProvider: { displays },
                                   rotationProvider: { _ in 0 })
        let undo = LastRestoreUndo(performer: engine, readiness: { true }, notifier: notifier,
                                   refresh: { XCTFail("可用性读取不能刷新呈现") })
        let url = store.undoURL(topologyKey: Displays.topologyIdentity(of: displays, rotation: { _ in 0 }).key)
        XCTAssertFalse(undo.isAvailable())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Snapshot(capturedAt: Date(), topology: [], spaces: [], windows: []).encoded().write(to: url)
        XCTAssertTrue(undo.isAvailable())
        try Data("broken".utf8).write(to: url)
        XCTAssertFalse(undo.isAvailable())
        XCTAssertEqual(try Data(contentsOf: url), Data("broken".utf8), "展示读取不隔离损坏文件")
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(undo.isAvailable())
    }

    func testQueuedRequestDoesNotKeepModuleAlive() {
        var undo: LastRestoreUndo? = makeUndo(queuedExecution: true)
        weak var weakUndo = undo
        undo?.request()
        undo = nil
        XCTAssertNil(weakUndo)
        queued.removeFirst()()
        XCTAssertEqual(performer.undoCalls, 0)
        XCTAssertEqual(refreshes, 0)
    }
}
