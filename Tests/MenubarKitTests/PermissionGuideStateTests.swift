import XCTest
@testable import MenubarKit

// ui-refactor 票 05：授权窗纯状态推导测试（spec §6）。
// 接缝：PermissionGuideState(status:) —— 每项行状态（已授权/未授权、路径行、行尾按钮 vs「已授权」）与底部状态条两态。
// 独立事实来源：spec §6 引文（测试自带字面量，不用实现常量自证）。
final class PermissionGuideStateTests: XCTestCase {
    private func status(accessibility: Bool, screenCapture: Bool, reconfirm: Bool = false) -> PermissionMonitor.Status {
        PermissionMonitor.Status(accessibilityGranted: accessibility, screenCaptureGranted: screenCapture,
                                 screenCaptureNeedsReconfirm: reconfirm)
    }

    /// 页头与两行静态文案逐字（§6），行序 = 辅助功能 → 屏幕与系统录音
    func testHeaderAndRowCopyVerbatim() {
        let state = PermissionGuideState(status: status(accessibility: false, screenCapture: false))
        XCTAssertEqual(state.title, "授权 Winductor")
        XCTAssertEqual(state.subtitle, "需要两项系统权限来读取和移动窗口。只在本机使用，不上传任何数据。")
        XCTAssertEqual(state.rows.map(\.kind), [.accessibility, .screenCapture])
        XCTAssertEqual(state.rows.map(\.name), ["辅助功能", "屏幕与系统录音"])
        XCTAssertEqual(state.rows.map(\.detail), ["读取和设置窗口的位置、大小，以及最小化与全屏。",
                                                  "读取各屏幕、各桌面上的窗口列表与标题，不录制画面。"])
        XCTAssertEqual(state.rows.map(\.symbolName), ["accessibility", "record.circle"])
    }

    /// 两项都未授权：两行都有灰色路径行 +【打开系统设置】，底部条 = 转圈 +「授权后这里会自动更新。」，无重启
    func testNoneGranted() {
        let state = PermissionGuideState(status: status(accessibility: false, screenCapture: false))
        XCTAssertEqual(state.rows.map(\.isGranted), [false, false])
        XCTAssertEqual(state.rows.map(\.settingsPath), ["系统设置 › 隐私与安全性 › 辅助功能",
                                                        "系统设置 › 隐私与安全性 › 屏幕与系统录音"])
        XCTAssertEqual(state.rows.map(\.showsOpenSettingsButton), [true, true])
        XCTAssertEqual(state.footer, .waiting)
        XCTAssertNil(state.footer.title)
        XCTAssertEqual(state.footer.caption, "授权后这里会自动更新。")
        XCTAssertFalse(state.footer.showsRestartButton)
    }

    /// 已授权一项（辅助功能）：该行换「已授权」、去路径行与按钮；另一行照旧；底部条仍等待
    func testOneGranted() {
        let state = PermissionGuideState(status: status(accessibility: true, screenCapture: false))
        XCTAssertEqual(state.rows.map(\.isGranted), [true, false])
        XCTAssertEqual(state.rows.map(\.settingsPath), [nil, "系统设置 › 隐私与安全性 › 屏幕与系统录音"])
        XCTAssertEqual(state.rows.map(\.showsOpenSettingsButton), [false, true])
        XCTAssertEqual(state.rows[0].grantedText, "已授权")
        XCTAssertEqual(state.footer, .waiting)
    }

    /// 只授权屏幕录音：对称
    func testOnlyScreenCaptureGranted() {
        let state = PermissionGuideState(status: status(accessibility: false, screenCapture: true))
        XCTAssertEqual(state.rows.map(\.isGranted), [false, true])
        XCTAssertEqual(state.footer, .waiting)
    }

    /// 两项齐备：两行「已授权」；底部条 = 绿勾 +「两项授权已齐备」/「重启 Winductor 后生效。」+【立即重启】
    func testBothGranted() {
        let state = PermissionGuideState(status: status(accessibility: true, screenCapture: true))
        XCTAssertEqual(state.rows.map(\.isGranted), [true, true])
        XCTAssertEqual(state.rows.map(\.showsOpenSettingsButton), [false, false])
        XCTAssertEqual(state.rows.map(\.settingsPath), [nil, nil])
        XCTAssertEqual(state.footer, .ready)
        XCTAssertEqual(state.footer.title, "两项授权已齐备")
        XCTAssertEqual(state.footer.caption, "重启 Winductor 后生效。")
        XCTAssertTrue(state.footer.showsRestartButton)
        XCTAssertEqual(state.footer.restartButtonTitle, "立即重启")
    }

    /// 屏幕录制预检通过但需重新确认（§8.4 信号）：该行仍按未授权呈现，底部条不进齐备态
    func testScreenCaptureReconfirmCountsAsNotGranted() {
        let state = PermissionGuideState(status: status(accessibility: true, screenCapture: true, reconfirm: true))
        XCTAssertEqual(state.rows.map(\.isGranted), [true, false])
        XCTAssertEqual(state.footer, .waiting)
    }
}
