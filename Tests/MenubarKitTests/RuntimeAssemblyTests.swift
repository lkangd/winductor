import Foundation
import XCTest
@testable import MenubarKit
import SnapshotEngine
import Core

// 票 18：未就绪门控接线测试（spec §4.6「两项齐备前保持未就绪：只轮询、不落盘快照」）。
// 接缝：RuntimeAssembly.makeSnapshotEngine 产物的公开 readinessGate（票 12 语义：
//       未就绪 = 引擎照常轮询但零落盘，该行为已由 SnapshotEngineTests 锁定）。
final class RuntimeAssemblyTests: XCTestCase {
    /// 就绪门跟着监视器走：未就绪 → false；两项齐备 → true
    func testReadinessGateFollowsMonitor() {
        let accessibilityGranted = Unboxed(false)
        let screenCaptureGranted = Unboxed(false)
        let monitor = PermissionMonitor(
            accessibilityProbe: { accessibilityGranted.value },
            screenCaptureProbe: { screenCaptureGranted.value },
            titleSampler: { [] }
        )
        let engine = RuntimeAssembly.makeSnapshotEngine(
            gatedBy: monitor,
            storeDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("wlr-runtime-assembly-tests-\(UUID().uuidString)")
        )
        XCTAssertFalse(engine.readinessGate(), "未就绪时引擎门必须关闭（零落盘）")

        accessibilityGranted.value = true
        screenCaptureGranted.value = true
        _ = monitor.checkNow()
        XCTAssertTrue(engine.readinessGate(), "两项齐备后引擎门放行落盘")
    }
}

/// 极简可变盒（测试探针用；避免 harness 改成 final class 引用型）
final class Unboxed<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
