import Foundation
import XCTest
import Core
@testable import MenubarKit
import RestoreEngine
import SnapshotEngine
import SpaceAdapter

// 实测缺陷回归（11-03「部分应用高度不对」）：RuntimeAssembly 只把消费器放在局部变量里，
// timer 回调又是 [weak self] → 装配函数返回即释放，pending 几何从未被消费（app.log 零条 deferred 行）。
// 期望：start() 后轮询自持存活，直到 stop()。
final class PendingGeometryConsumerTests: XCTestCase {
    func testStartedConsumerStaysAliveWithoutExternalOwnerUntilStopped() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wlr-pending-consumer-\(UUID().uuidString)")
        let geometryStore = DeferredGeometryStore(directory: dir)
        let engine = SnapshotEngine(store: SnapshotStore(directory: dir), spaces: nil,
                                    displaysProvider: { [] }, notificationCenters: [])
        weak var weakConsumer: PendingGeometryConsumer?
        do {
            let consumer = PendingGeometryConsumer(
                store: geometryStore,
                applier: DeferredGeometryApplier(store: geometryStore, displaysProvider: { [] }),
                adapter: SpaceAdapter(), snapshotEngine: engine)
            consumer.start(interval: 60, center: NotificationCenter())  // Space 切换观察也须在 stop 时断环
            weakConsumer = consumer
        }
        XCTAssertNotNil(weakConsumer, "启动后的消费轮询必须自持存活（装配处不持有引用）")

        weakConsumer?.stop()
        XCTAssertNil(weakConsumer, "stop 后释放（不泄漏）")
    }

    /// 只补写窗在活跃 Space 的条目（并发/慢窗不阻塞由 DeferredGeometryApplier.applyPending 负责）
    func testConsumesOnlyEntriesOnActiveSpaces() {
        let pending = [PendingGeometryEntry(windowID: 1, displayUUID: "A", x: 0, y: 0, w: 1, h: 1),
                       PendingGeometryEntry(windowID: 2, displayUUID: "A", x: 0, y: 0, w: 1, h: 1),
                       PendingGeometryEntry(windowID: 3, displayUUID: "A", x: 0, y: 0, w: 1, h: 1)]
        var batch: [UInt32]?
        PendingGeometryConsumer.consume(pending: pending, activeSpaceIDs: [10],
                                        spaceByWindow: [1: 10, 2: 10, 3: 99],
                                        shouldYield: { false }) { batch = $0 }
        XCTAssertEqual(batch, [1, 2], "窗不在活跃 Space：不补写")
    }

    func testYieldsWhenRestoreStarts() {
        let pending = [PendingGeometryEntry(windowID: 1, displayUUID: "A", x: 0, y: 0, w: 1, h: 1)]
        var applied = false
        PendingGeometryConsumer.consume(pending: pending, activeSpaceIDs: [10], spaceByWindow: [1: 10],
                                        shouldYield: { true }) { _ in applied = true }
        XCTAssertFalse(applied, "恢复管线已开始：让出，不补写")
    }
}
