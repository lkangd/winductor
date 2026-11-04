import XCTest
@testable import Core

// SpaceKindTests — SpaceEntry.kind 语义值共享映射（spec §5.1 实测：0=用户桌面、4=全屏）。
// 接缝：Core.Seams.swift 的 SpaceKind（DebugCLI list-spaces/move-window 与 RestoreEngine 共用）。
final class SpaceKindTests: XCTestCase {
    /// kind 语义值锁死（SLS 实测口径，spec §5.1）
    func testKindValues() {
        XCTAssertEqual(SpaceKind.user, 0)
        XCTAssertEqual(SpaceKind.fullscreen, 4)
    }

    /// kind → 人读名（未知值回退 ?kind=<n>，与既有 DebugCLI 输出同拼写）
    func testKindName() {
        XCTAssertEqual(SpaceKind.kindName(SpaceKind.user), "user")
        XCTAssertEqual(SpaceKind.kindName(SpaceKind.fullscreen), "fullscreen")
        XCTAssertEqual(SpaceKind.kindName(2), "?kind=2")
    }
}
