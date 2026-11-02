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
