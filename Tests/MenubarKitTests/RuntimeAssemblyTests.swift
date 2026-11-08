import Foundation
import XCTest
@testable import MenubarKit
import Core
import SnapshotEngine

/// 极简可变盒（测试探针用；避免 harness 改成 final class 引用型）
final class Unboxed<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

// display-presets 票 03：保存预设流程的装配接线（未就绪门 = PermissionMonitor；恢复进行中 = SkyLightSession 独占）。
// 接缝：RuntimeAssembly.makeSavePresetFlow 产物的 availability()。
final class RuntimeAssemblyTests: XCTestCase {
    /// 可用性跟着观察者与恢复管线走：未就绪 → notReady；就绪 → available；管线独占中 → restoring
    func testLayoutCaptureAvailabilityFollowsMonitorAndRestorePipeline() throws {
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

    /// 保存与覆盖共用的拍快照：本应用自身窗口（如开着的管理窗口）不入快照，其余窗口与拓扑原样
    func testSharedLayoutCaptureExcludesOwnWindows() throws {
        func window(_ bundleID: String) -> SnapshotWindow {
            SnapshotWindow(bundleID: bundleID, title: bundleID, siblingIndex: 0, displayUUID: "A",
                           spaceIndex: 1, x: 0, y: 0, w: 0.5, h: 0.5, minimized: false)
        }
        let topology = ObservedTopology(screens: [])
        let raw = LayoutCapture(snapshot: Snapshot(capturedAt: Date(timeIntervalSince1970: 0), topology: [], spaces: [],
                                                   windows: [window("com.example.editor"), window("app.winductor"),
                                                             window("com.example.terminal")]),
                                topology: topology)

        let capture = RuntimeAssembly.layoutCapture(excludingWindowsOf: "app.winductor") { raw }
        let captured = try capture()

        XCTAssertEqual(captured.snapshot.windows.map(\.bundleID), ["com.example.editor", "com.example.terminal"])
        XCTAssertEqual(captured.topology.identity.key, topology.identity.key)
    }
}
