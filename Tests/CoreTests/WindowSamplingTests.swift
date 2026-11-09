import CoreGraphics
import XCTest
@testable import Core

// WindowSamplingTests — CG 窗口字典 → 候选采样（票 dp-11；诊断 acceptance4 R2）。
// 接缝：CGWindowListEnumerator.sample(from:hiddenPIDs:)（sample() 的纯函数核心）。
final class WindowSamplingTests: XCTestCase {
    private func dict(_ wid: Int, pid: Int = 7, onscreen: Bool? = nil) -> [String: Any] {
        var d: [String: Any] = [
            kCGWindowLayer as String: 0,
            kCGWindowNumber as String: wid,
            kCGWindowOwnerPID as String: pid,
            "kCGWindowBundleID": "com.t",
            kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 400, "Height": 300],
        ]
        if let onscreen { d[kCGWindowIsOnscreen as String] = onscreen }
        return d
    }

    /// kCGWindowIsOnscreen 只在窗真在屏上时出现（实测 376 个 layer-0 窗只有 8 个带键）：缺键 = 不在屏
    func testMissingOnscreenKeyMeansOffscreen() {
        let samples = CGWindowListEnumerator.sample(from: [dict(1), dict(2, onscreen: true)], hiddenPIDs: [])
        XCTAssertEqual(samples.map(\.isOnscreen), [false, true])
    }

    /// 所属应用被隐藏 → appHidden（按 pid 对位）
    func testAppHiddenFromHiddenPIDs() {
        let samples = CGWindowListEnumerator.sample(from: [dict(1, pid: 7), dict(2, pid: 8)], hiddenPIDs: [8])
        XCTAssertEqual(samples.map(\.appHidden), [false, true])
    }
}
