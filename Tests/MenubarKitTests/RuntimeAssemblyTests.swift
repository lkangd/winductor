import Foundation
import XCTest
@testable import MenubarKit
import SnapshotEngine
import Core

// 票 18：未就绪门控接线测试（spec §4.6「两项齐备前保持未就绪：只轮询、不落盘快照」）。
// 接缝：RuntimeAssembly.makeSnapshotEngine 产物的公开 readinessGate（票 12 语义：
//       未就绪 = 引擎照常轮询但零落盘，该行为已由 SnapshotEngineTests 锁定）。
// 评审修复：WorkspaceEventAccelerator 接线断言（spec §7.5 应用启退/Space 切换加速器）。
final class RuntimeAssemblyTests: XCTestCase {
    /// 就绪门跟着观察者走：未就绪 → false；两项齐备 → true
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

    /// 评审修复接线断言：WorkspaceEventAccelerator 把 NSWorkspace 中心事件（应用启退/Space 切换）
    /// 接进 engine.pollNow()（spec §7.5 加速器）；stop 后摘除观察。中心注入，不碰真实 NSWorkspace。
    func testWorkspaceEventAcceleratorWiresWorkspaceEventsToEnginePollNow() {
        let center = NotificationCenter()
        let enumerator = CountingEnumerator()
        let engine = SnapshotEngine(
            store: SnapshotStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("wlr-accelerator-tests-\(UUID().uuidString)")),
            spaces: nil,
            enumerator: enumerator,
            displaysProvider: { [] },
            notificationCenters: [center])
        defer { engine.stop() }

        _ = engine.pollNow()  // 基线差分：第 1 次采样
        XCTAssertEqual(enumerator.callCount, 1)

        let accelerator = WorkspaceEventAccelerator(engine: engine, center: center)
        accelerator.start()
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        XCTAssertEqual(enumerator.callCount, 4,
                       "Space 切换/应用启退事件必须各立即差分一次（spec §7.5 加速器）")

        accelerator.stop()
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        XCTAssertEqual(enumerator.callCount, 4, "stop 后观察者应摘除，不再差分")
    }
}

/// 极简可变盒（测试探针用；避免 harness 改成 final class 引用型）
final class Unboxed<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// 采样计数桩：每次采样 windowID 递增 ⇒ 引擎每次差分都检出变化（加速器断言只看采样次数）
private final class CountingEnumerator: WindowEnumerating, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func sample() -> [CGWindowSample] {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return [CGWindowSample(windowID: UInt32(count), pid: 1, bundleID: "com.t.probe", title: nil,
                               bounds: CGRect(x: 0, y: 0, width: 100, height: 100), isOnscreen: true)]
    }
}
