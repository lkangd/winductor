import XCTest
@testable import MenubarKit

// 票 18：权限监视器状态机测试（spec §4.6/§8.3）。
// 接缝：PermissionMonitor.checkNow()（公开检测入口，检测函数可注入）。
// 独立事实来源：spec §4.6 —— 两项（辅助功能、屏幕与系统录音）齐备才算就绪；
// 缺项引导顺序「辅助功能 → 屏幕与系统录音」；状态变化对外发回调（§8.3 每 2s 自动检测推进）。
final class PermissionMonitorTests: XCTestCase {
    private var accessibilityGranted = false
    private var screenCaptureGranted = false
    private var windowTitles: [String?] = []
    private var statusChanges: [PermissionMonitor.Status] = []

    private func makeMonitor() -> PermissionMonitor {
        let monitor = PermissionMonitor(
            accessibilityProbe: { [unowned self] in self.accessibilityGranted },
            screenCaptureProbe: { [unowned self] in self.screenCaptureGranted },
            titleSampler: { [unowned self] in self.windowTitles }
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

    // MARK: §8.4 屏幕录制定期重确认（前后对比：之前可读 → 现在有窗口但标题全空）

    /// 就绪运行中标题全空 → 降回未就绪 + 重确认信号 + 一次回调（§8.4 自动降级）
    func testRuntimeTitleLossDemotesToReconfirmNotReady() {
        accessibilityGranted = true
        screenCaptureGranted = true
        windowTitles = ["邮件", "终端"]
        let monitor = makeMonitor()
        XCTAssertTrue(monitor.checkNow().isReady)
        statusChanges.removeAll()

        windowTitles = [nil, nil]
        let status = monitor.checkNow()
        XCTAssertFalse(status.isReady)
        XCTAssertTrue(status.screenCaptureNeedsReconfirm)
        XCTAssertEqual(status.missing, [.screenCapture])
        XCTAssertEqual(statusChanges, [status])
    }

    /// 首样本就全空不判降级（无「之前可读」基线；首启未授权由预检探针说话）
    func testFirstSampleAllEmptyDoesNotLapse() {
        accessibilityGranted = true
        screenCaptureGranted = true
        windowTitles = [nil, nil]
        let status = makeMonitor().checkNow()
        XCTAssertTrue(status.isReady)
        XCTAssertFalse(status.screenCaptureNeedsReconfirm)
    }

    /// 标题重新可读且预检通过 → 重确认解除、恢复就绪
    func testReconfirmClearsWhenTitlesReadableAndPreflightTrue() {
        accessibilityGranted = true
        screenCaptureGranted = true
        windowTitles = ["邮件"]
        let monitor = makeMonitor()
        _ = monitor.checkNow()
        windowTitles = [nil]
        XCTAssertFalse(monitor.checkNow().isReady)

        windowTitles = ["邮件"]
        let status = monitor.checkNow()
        XCTAssertTrue(status.isReady)
        XCTAssertFalse(status.screenCaptureNeedsReconfirm)
    }

    /// TCC 收回后标题持续不可读：预检变 false 也不抹掉重确认信号（保持 §8.4 未就绪）
    func testStaysReconfirmWhileTitlesUnreadableEvenIfPreflightFlipsFalse() {
        accessibilityGranted = true
        screenCaptureGranted = true
        windowTitles = ["邮件"]
        let monitor = makeMonitor()
        _ = monitor.checkNow()
        windowTitles = [nil]
        _ = monitor.checkNow()

        screenCaptureGranted = false
        let status = monitor.checkNow()
        XCTAssertFalse(status.isReady)
        XCTAssertTrue(status.screenCaptureNeedsReconfirm)
    }
}
