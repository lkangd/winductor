import Foundation
import XCTest
@testable import MenubarKit
import Core

/// 极简可变盒（测试探针用；避免 harness 改成 final class 引用型）
final class Unboxed<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

// 票 03：保存预设流程的装配接线（未就绪门 = PermissionMonitor；恢复进行中 = SkyLightSession 独占）。
// 接缝：RuntimeAssembly.makeSavePresetFlow 产物的 availability()。
final class RuntimeAssemblyTests: XCTestCase {
    /// 可用性跟着观察者与恢复管线走：未就绪 → notReady；就绪 → available；管线独占中 → restoring
    func testSavePresetAvailabilityFollowsMonitorAndRestorePipeline() throws {
        let granted = Unboxed(false)
        let monitor = PermissionMonitor(
            accessibilityProbe: { granted.value },
            screenCaptureProbe: { granted.value },
            titleSampler: { [] }
        )
        let session = SkyLightSession()
        let flow = RuntimeAssembly.makeSavePresetFlow(
            gatedBy: monitor,
            store: PresetStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("winductor-assembly-\(UUID().uuidString)")),
            spaces: nil,
            session: session,
            isMirrored: { false })
        XCTAssertEqual(flow.availability(), .notReady, "未就绪时保存禁用")

        granted.value = true
        _ = monitor.checkNow()
        XCTAssertEqual(flow.availability(), .available, "两项齐备后可保存")

        session.exclusive("restore") {
            XCTAssertEqual(flow.availability(), .restoring, "恢复管线独占期间禁用")
        }
    }
}
