import AXFacade
import CoreGraphics
import Foundation
@testable import RestoreEngine
import XCTest

// AXWindowIndexTests.swift — L1 AX 索引收窄（恢复提速）：
// 只对目标窗的 CG owner pid 建索引（全量 app 遍历被无响应 helper 进程拖到 ~4.7s/轮，11-03 日志）；
// 所属 app 已建索引却不在表内的窗 = 非 AX 窗口，L1 直接放弃（实测 L1 尾部 1.5s 全由它们构成）。
final class AXWindowIndexTests: XCTestCase {
    private func cgInfo(_ wid: UInt32, pid: Int32) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: wid), kCGWindowOwnerPID as String: NSNumber(value: pid)]
    }

    func testOwnersMapsOnlyRequestedWindows() {
        let info = [cgInfo(10, pid: 100), cgInfo(11, pid: 100), cgInfo(20, pid: 200), cgInfo(30, pid: 300)]
        XCTAssertEqual(AXFacade.owners(of: [10, 11, 30], in: info), [10: 100, 11: 100, 30: 300])
    }

    func testOwnersSkipsUnknownWindowsAndMalformedEntries() {
        let info: [[String: Any]] = [cgInfo(10, pid: 0), [kCGWindowNumber as String: NSNumber(value: 11)], cgInfo(12, pid: 7)]
        XCTAssertEqual(AXFacade.owners(of: [10, 11, 12, 99], in: info), [12: 7])
    }

    func testOwnersEmptyRequestYieldsEmptyMap() {
        XCTAssertEqual(AXFacade.owners(of: [], in: [cgInfo(10, pid: 100)]), [:])
    }

    func testNotAXWindowsOnlyCountsWindowsOfSuccessfullyIndexedApps() {
        // pid 100 已建索引：wid 11 不在表内 = 非 AX 窗；pid 200 AX 读失败（超时）：未知，不判定
        let missing = AXGeometryWriter.notAXWindows(
            owners: [10: 100, 11: 100, 20: 200], index: [10], indexedPIDs: [100])
        XCTAssertEqual(missing, [11])
    }
}
