import XCTest
@testable import MenubarKit

// 票 18：权限监视器状态机测试（spec §4.6/§8.3）。
// 接缝：PermissionMonitor.checkNow()（公开检测入口，检测函数可注入）。
// 独立事实来源：spec §4.6 —— 两项（辅助功能、屏幕与系统录音）齐备才算就绪；
// 缺项引导顺序「辅助功能 → 屏幕与系统录音」；状态变化对外发回调（§8.3 每 2s 自动检测推进）。
final class PermissionMonitorTests: XCTestCase {
    private var accessibilityGranted = false
    private var screenCaptureGranted = false
    private var statusChanges: [PermissionMonitor.Status] = []

    private func makeMonitor() -> PermissionMonitor {
        let monitor = PermissionMonitor(
            accessibilityProbe: { [unowned self] in self.accessibilityGranted },
            screenCaptureProbe: { [unowned self] in self.screenCaptureGranted }
        )
        monitor.onStatusChange = { [unowned self] status in self.statusChanges.append(status) }
        return monitor
    }

    /// 两项全缺 = 未就绪；缺失项按引导顺序（辅助功能 → 屏幕录音）
    func testBothMissingIsNotReadyWithMissingInGuideOrder() {
        accessibilityGranted = false
        screenCaptureGranted = false
        let status = makeMonitor().checkNow()
        XCTAssertFalse(status.isReady)
        XCTAssertEqual(status.missing, [.accessibility, .screenCapture])
    }

    /// 只缺辅助功能：缺失列表只含辅助功能（顺序事实来源：spec §4.6「顺序辅助功能 → 屏幕与系统录音」）
    func testAccessibilityMissingAlone() {
        accessibilityGranted = false
        screenCaptureGranted = true
        let status = makeMonitor().checkNow()
        XCTAssertFalse(status.isReady)
        XCTAssertEqual(status.missing, [.accessibility])
    }

    /// 只缺屏幕录制：缺失列表只含屏幕录制
    func testScreenCaptureMissingAlone() {
        accessibilityGranted = true
        screenCaptureGranted = false
        let status = makeMonitor().checkNow()
        XCTAssertFalse(status.isReady)
        XCTAssertEqual(status.missing, [.screenCapture])
    }

    /// 两项齐备 = ready；从未就绪到齐备对外发一次变化回调（§8.3「检测推进」）
    func testBothGrantedBecomesReadyAndFiresChangeCallback() {
        accessibilityGranted = false
        screenCaptureGranted = false
        let monitor = makeMonitor()
        let initial = monitor.checkNow()
        XCTAssertFalse(initial.isReady)
        XCTAssertEqual(statusChanges.count, 1, "首次检测即建立基线状态，也应通知一次")

        accessibilityGranted = true
        screenCaptureGranted = true
        let ready = monitor.checkNow()
        XCTAssertTrue(ready.isReady)
        XCTAssertEqual(statusChanges.count, 2)
        XCTAssertEqual(statusChanges.last, ready)
        XCTAssertEqual(monitor.status, ready)
    }

    /// 状态无变化不重复回调（每 2s 轮询的幂等性）
    func testUnchangedStatusDoesNotFireCallbackAgain() {
        accessibilityGranted = true
        screenCaptureGranted = true
        let monitor = makeMonitor()
        _ = monitor.checkNow()
        _ = monitor.checkNow()
        XCTAssertEqual(statusChanges.count, 1)
    }
}
