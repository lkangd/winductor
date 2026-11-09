import XCTest
@testable import SpaceAdapter

/// 桥接操作限时执行（实测缺陷：performBridgedMove 是无超时同步私有 API，
/// WindowServer 迁移单窗可阻塞 159s 拖死整轮恢复管线；8s 上限 + 超时可观测后继续管线）
final class SpaceAdapterBoundedMoveTests: XCTestCase {
    func testBoundedMoveReturnsCompletedWhenRunnerFinishesInTime() {
        let outcome = SpaceAdapter.performBridgedMoveBounded([1], spaceID: 9, timeout: 2) { _, _ in nil }
        guard case .completed(let issue) = outcome else {
            XCTFail("及时完成应返回 completed"); return
        }
        XCTAssertNil(issue)
    }

    func testBoundedMoveReturnsCompletedWithIssueWhenRunnerReports() {
        let outcome = SpaceAdapter.performBridgedMoveBounded([1], spaceID: 9, timeout: 2) { _, _ in "op failed" }
        guard case .completed(let issue) = outcome else {
            XCTFail("应返回 completed"); return
        }
        XCTAssertEqual(issue, "op failed")
    }

    func testBoundedMoveTimesOutWhenRunnerBlocks() {
        let start = Date()
        let outcome = SpaceAdapter.performBridgedMoveBounded([1], spaceID: 9, timeout: 0.2) { _, _ in
            Thread.sleep(forTimeInterval: 2)  // 模拟 WindowServer 长阻塞
            return nil
        }
        if case .completed = outcome { XCTFail("阻塞 runner 应超时") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "超时上限应生效，不等待 runner 结束")
    }
}

/// SkyLight 读取限时（楔死时 spaceIDs 查询同样阻塞 111s，一并限界）
final class SpaceAdapterBoundedReadTests: XCTestCase {
    func testBoundedReadReturnsValueWhenReaderFinishesInTime() {
        let ids = SpaceAdapter.spaceIDsBounded(7, timeout: 2) { _ in [5] }
        XCTAssertEqual(ids, [5])
    }

    func testBoundedReadReturnsNilWhenReaderBlocks() {
        let start = Date()
        let ids = SpaceAdapter.spaceIDsBounded(7, timeout: 0.2) { _ in
            Thread.sleep(forTimeInterval: 2)
            return [5]
        }
        XCTAssertNil(ids, "阻塞读取应超时返回 nil（未知归属）")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "超时上限应生效")
    }
}

/// 桥接后归属结算：轮询代替固定 1.2s 等待（恢复提速：实测 5 次桥接串行 = 6s 纯等待）
final class SpaceAdapterSettleTests: XCTestCase {
    /// 线程安全的调用计数 reader（spaceIDsBounded 在全局队列上调用 reader）
    final class CountingReader: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        let respond: (Int) -> [Int64]?
        init(_ respond: @escaping (Int) -> [Int64]?) { self.respond = respond }
        func read(_ wid: UInt32) throws -> [Int64] {
            lock.lock(); calls += 1; let n = calls; lock.unlock()
            guard let ids = respond(n) else { Thread.sleep(forTimeInterval: 2); return [] }
            return ids
        }
    }

    func testReturnsMovedAsSoonAsAttributionChanges() {
        let reader = CountingReader { n in n >= 2 ? [9] : [5] }
        let start = Date()
        let result = SpaceAdapter.awaitAttributionChange(
            [1], before: [[5]], settle: 1.2, poll: 0.02, readTimeout: 1, reader: reader.read)
        XCTAssertEqual(result, .moved)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.6, "归属变更后应立即返回，不等满 settle")
    }

    func testMultiWindowWaitsUntilEveryWindowChanged() {
        // wid 1 立即变更，wid 2 第 4 次读才变更：两者都变更才提前返回
        let r1 = CountingReader { _ in [9] }
        let r2 = CountingReader { n in n >= 4 ? [9] : [5] }
        let result = SpaceAdapter.awaitAttributionChange(
            [1, 2], before: [[5], [5]], settle: 2, poll: 0.02, readTimeout: 1,
            reader: { $0 == 1 ? try r1.read($0) : try r2.read($0) })
        XCTAssertEqual(result, .moved)
    }

    func testPartialChangeAtDeadlineStillCountsAsMoved() {
        let result = SpaceAdapter.awaitAttributionChange(
            [1, 2], before: [[5], [5]], settle: 0.2, poll: 0.02, readTimeout: 1,
            reader: { $0 == 1 ? [9] : [5] })
        XCTAssertEqual(result, .moved, "与原口径一致：任一窗归属变更即视为生效")
    }

    func testUnchangedAfterFullSettleIsNoOp() {
        let start = Date()
        let result = SpaceAdapter.awaitAttributionChange(
            [1], before: [[5]], settle: 0.3, poll: 0.02, readTimeout: 1, reader: { _ in [5] })
        XCTAssertEqual(result, .unchanged)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.3, "no-op 判定须等满 settle")
    }

    func testReadTimeoutIsUnknown() {
        let reader = CountingReader { _ in nil }
        let result = SpaceAdapter.awaitAttributionChange(
            [1], before: [[5]], settle: 1.2, poll: 0.02, readTimeout: 0.1, reader: reader.read)
        XCTAssertEqual(result, .unknown(wid: 1))
    }
}

/// 运行时 no-op 失效标记作用域 = 一轮恢复（display-presets 票 12：一次 no-op 曾毒化整个进程的 L2）
final class SpaceAdapterRuntimeNoOpTests: XCTestCase {
    func testNoOpMarkHoldsUntilClearedForNextRound() {
        let adapter = SpaceAdapter()
        adapter.markRuntimeNoOp(detail: "test")
        XCTAssertEqual(adapter.probeLayer(.bridge).reason, "no-op", "本轮内 bridge 层保持失效")

        adapter.clearRuntimeNoOp()
        XCTAssertNotEqual(adapter.probeLayer(.bridge).reason, "no-op", "新一轮不再带上一轮的 no-op 标记")
    }
}
