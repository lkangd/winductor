import AppKit
import SwiftUI
import XCTest
@testable import MenubarKit

// 票 18 起、ui-refactor 票 05 改写：授权窗测试（spec §6 逐字文案 + 推进行为 + 窗口形态）。
// 接缝：PermissionGuideWindow 的公开产物——呈现文本（visibleTexts/statusTexts）、按钮可见性、
//       行尾【打开系统设置】与底部【立即重启】的点击入口（视图按钮同走 press* 方法；注入闭包捕获）。
// 独立事实来源：spec §6 引文（测试自带字面量，不用实现常量自证）。
final class PermissionGuideWindowTests: XCTestCase {
    private var openedSettings: [PermissionMonitor.Kind] = []
    private var relaunchCount = 0
    private var guide: PermissionGuideWindow!

    override func setUp() {
        openedSettings = []
        relaunchCount = 0
        guide = PermissionGuideWindow(
            paneNames: .forSystem(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)),
            openSettings: { [unowned self] kind in self.openedSettings.append(kind) },
            relaunch: { [unowned self] in self.relaunchCount += 1 }
        )
    }

    private func status(accessibility: Bool, screenCapture: Bool) -> PermissionMonitor.Status {
        PermissionMonitor.Status(accessibilityGranted: accessibility, screenCaptureGranted: screenCapture,
                                 screenCaptureNeedsReconfirm: false)
    }

    /// §6 全文逐字：页头标题与说明、两项名称/说明/路径（macOS 15 口径，票 09）、底部等待提示
    func testSpec6TextsVerbatim() {
        let texts = guide.visibleTexts
        XCTAssertTrue(texts.contains("授权 Winductor"))
        XCTAssertTrue(texts.contains("需要两项系统权限来读取和移动窗口。只在本机使用，不上传任何数据。"))
        XCTAssertTrue(texts.contains("辅助功能"))
        XCTAssertTrue(texts.contains("读取和设置窗口的位置、大小，以及最小化与全屏。"))
        XCTAssertTrue(texts.contains("系统设置 › 隐私与安全性 › 辅助功能"))
        XCTAssertTrue(texts.contains("录屏与系统录音"))
        XCTAssertTrue(texts.contains("读取各屏幕、各桌面上的窗口列表与标题，不录制画面。"))
        XCTAssertTrue(texts.contains("系统设置 › 隐私与安全性 › 录屏与系统录音"))
        XCTAssertTrue(texts.contains("授权后这里会自动更新。"))
        XCTAssertEqual(guide.settingsButtonTitle, "打开系统设置")
    }

    /// 初始态（未授权）：两个【打开系统设置】可见，底部等待提示，【立即重启】隐藏
    func testInitialStateIsWaitingWithoutRestart() {
        XCTAssertEqual(guide.statusTexts, ["授权后这里会自动更新。"])
        XCTAssertEqual(guide.visibleSettingsButtons, [.accessibility, .screenCapture])
        XCTAssertFalse(guide.isRestartButtonVisible)
    }

    /// 行尾【打开系统设置】→ 深链各自面板
    func testSettingsButtonsRouteToTheirPanels() {
        guide.pressOpenSettings(.accessibility)
        guide.pressOpenSettings(.screenCapture)
        XCTAssertEqual(openedSettings, [.accessibility, .screenCapture])
    }

    /// 已授权一项：该行按钮换「已授权」（不可点），路径行消失；另一行照旧
    func testOneGrantedHidesThatRowsButton() {
        guide.update(status: status(accessibility: true, screenCapture: false), hasBeenNotReady: true)
        XCTAssertEqual(guide.visibleSettingsButtons, [.screenCapture])
        XCTAssertFalse(guide.visibleTexts.contains("系统设置 › 隐私与安全性 › 辅助功能"))
        XCTAssertTrue(guide.visibleTexts.contains("已授权"))
        guide.pressOpenSettings(.accessibility)
        guide.pressOpenSettings(.screenCapture)
        XCTAssertEqual(openedSettings, [.screenCapture])
        XCTAssertEqual(guide.statusTexts, ["授权后这里会自动更新。"])
        XCTAssertFalse(guide.isRestartButtonVisible)
    }

    /// 两项齐备：底部条换「两项授权已齐备」/「重启 Winductor 后生效。」+【立即重启】，能干净重启
    func testReadyShowsRestartPromptAndRelaunch() {
        guide.update(status: status(accessibility: true, screenCapture: true), hasBeenNotReady: true)
        XCTAssertEqual(guide.statusTexts, ["两项授权已齐备", "重启 Winductor 后生效。"])
        XCTAssertEqual(guide.visibleSettingsButtons, [])
        XCTAssertTrue(guide.isRestartButtonVisible)
        XCTAssertEqual(guide.restartButtonTitle, "立即重启")

        guide.pressRestart()
        XCTAssertEqual(relaunchCount, 1)
    }

    /// 启动即就绪后按需打开：底部条「两项授权已齐备」/「Winductor 已可正常保存和恢复布局。」，无【立即重启】、入口不响应
    func testAlreadyReadyShowsNoRestart() {
        guide.update(status: status(accessibility: true, screenCapture: true), hasBeenNotReady: false)
        XCTAssertEqual(guide.statusTexts, ["两项授权已齐备", "Winductor 已可正常保存和恢复布局。"])
        XCTAssertFalse(guide.isRestartButtonVisible)
        guide.pressRestart()
        XCTAssertEqual(relaunchCount, 0)
    }

    /// 未齐备时重启入口不响应（按钮不可见）
    func testRestartIgnoredWhileWaiting() {
        guide.pressRestart()
        XCTAssertEqual(relaunchCount, 0)
    }

    /// 齐备后又失一项（重启前被收回）：回到等待提示并隐藏重启按钮
    func testNotReadyAgainHidesRestart() {
        guide.update(status: status(accessibility: true, screenCapture: true), hasBeenNotReady: true)
        guide.update(status: status(accessibility: true, screenCapture: false), hasBeenNotReady: true)
        XCTAssertEqual(guide.statusTexts, ["授权后这里会自动更新。"])
        XCTAssertFalse(guide.isRestartButtonVisible)
        XCTAssertEqual(guide.visibleSettingsButtons, [.screenCapture])
    }

    /// 窗口形态（§6）：SwiftUI 宿主、宽 580、透明标题栏（内容铺满）、浮层、关闭不释放
    func testWindowShape() {
        let window = guide.window
        XCTAssertTrue(window.contentView is NSHostingView<PermissionGuideView>)
        XCTAssertEqual(window.frame.width, 580)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertEqual(window.level, .floating)
    }

    /// 深链 URL 常量独立核对（任务书指定面板标识）
    func testSystemSettingsURLs() {
        XCTAssertEqual(SystemSettingsOpener.accessibilityPaneURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(SystemSettingsOpener.screenCapturePaneURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
}
