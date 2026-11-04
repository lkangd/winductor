import AppKit
import XCTest
@testable import MenubarKit

// 票 18：首启授权引导窗测试（spec §8.3 逐字文案 + 推进行为）。
// 接缝：PermissionGuideWindow 的公开产物——呈现文本（contentLabels/statusText）、
//       两个【打开系统设置】按钮与【立即重启】按钮的行为（注入闭包捕获）。
// 独立事实来源：spec §8.3 引文（测试自带字面量，不用实现常量自证）。
final class PermissionGuideWindowTests: XCTestCase {
    private var openedSettings: [PermissionMonitor.Kind] = []
    private var relaunchCount = 0
    private var guide: PermissionGuideWindow!

    override func setUp() {
        openedSettings = []
        relaunchCount = 0
        guide = PermissionGuideWindow(
            openSettings: { [unowned self] kind in self.openedSettings.append(kind) },
            relaunch: { [unowned self] in self.relaunchCount += 1 }
        )
    }

    private var texts: [String] { guide.contentLabels.map(\.stringValue) }

    /// §8.3 全文逐字：标题、导语、①②两项、两项面板指引
    func testSpec83StaticTextsVerbatim() {
        XCTAssertTrue(texts.contains("先授权，才能开始"))
        XCTAssertTrue(texts.contains("本应用需要两项系统权限才能读取和移动窗口。授权仅用于本机恢复窗口，不上传任何数据。"))
        XCTAssertTrue(texts.contains("① 辅助功能 —— 用于读取和设置窗口位置、最小化与全屏。"))
        XCTAssertTrue(texts.contains("→ 隐私与安全性 > 辅助功能，打开「Winductor」"))
        XCTAssertTrue(texts.contains("② 屏幕与系统录音 —— 用于读取所有屏幕、所有桌面上的窗口列表与标题。"))
        XCTAssertTrue(texts.contains("→ 隐私与安全性 > 屏幕与系统录音，打开「Winductor」"))
    }

    /// 初始态：状态行「检测中……」，【立即重启】隐藏（§8.3「检测中……」→ 齐备才提示重启）
    func testInitialStateIsDetectingWithoutRestart() {
        XCTAssertEqual(guide.statusText, "检测中……")
        XCTAssertFalse(guide.isRestartButtonVisible)
    }

    /// ①【打开系统设置】→ 深链辅助功能面板；② → 深链屏幕与系统录音面板
    func testSettingsButtonsRouteToTheirPanels() {
        let buttons = guide.settingsButtons
        XCTAssertEqual(buttons.count, 2)
        XCTAssertEqual(buttons[0].title, "打开系统设置")
        XCTAssertEqual(buttons[1].title, "打开系统设置")

        buttons[0].performClick(nil)
        buttons[1].performClick(nil)
        XCTAssertEqual(openedSettings, [.accessibility, .screenCapture])
    }

    /// 两项齐备：状态行换「✓ 两项授权已齐备。请重启应用使授权生效。」+【立即重启】出现且能干净重启
    func testReadyShowsRestartPromptAndRelaunch() {
        let ready = PermissionMonitor.Status(accessibilityGranted: true, screenCaptureGranted: true,
                                             screenCaptureNeedsReconfirm: false)
        guide.update(status: ready)
        XCTAssertEqual(guide.statusText, "✓ 两项授权已齐备。请重启应用使授权生效。")
        XCTAssertTrue(guide.isRestartButtonVisible)
        XCTAssertEqual(guide.restartButtonTitle, "立即重启")

        guide.restartButton.performClick(nil)
        XCTAssertEqual(relaunchCount, 1)
    }

    /// 齐备后又失一项目（重启前被收回）：回到「检测中……」并隐藏重启按钮
    func testNotReadyAgainHidesRestart() {
        let ready = PermissionMonitor.Status(accessibilityGranted: true, screenCaptureGranted: true,
                                             screenCaptureNeedsReconfirm: false)
        guide.update(status: ready)
        let lapsed = PermissionMonitor.Status(accessibilityGranted: true, screenCaptureGranted: false,
                                              screenCaptureNeedsReconfirm: false)
        guide.update(status: lapsed)
        XCTAssertEqual(guide.statusText, "检测中……")
        XCTAssertFalse(guide.isRestartButtonVisible)
    }

    /// 深链 URL 常量独立核对（任务书指定面板标识）
    func testSystemSettingsURLs() {
        XCTAssertEqual(SystemSettingsOpener.accessibilityPaneURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(SystemSettingsOpener.screenCapturePaneURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
}
