import AppKit
import XCTest
@testable import MenubarKit

// 票 18：屏幕录制重确认菜单引导块测试（spec §8.4，不弹窗的被动引导）。
// 接缝：ScreenCaptureReconfirmGuide.install 对占位菜单的顶部拼接行为。
// 独立事实来源：spec §8.4 逐字引文——状态行「屏幕录制权限需重新确认」点击直达系统设置；
// 菜单内固定说明「macOS 会定期要求重新确认屏幕录制权限。请在系统设置中重新打开开关，然后重启应用。」
final class ScreenCaptureReconfirmGuideTests: XCTestCase {
    private final class ActionTarget: NSObject {
        let handler: () -> Void
        init(handler: @escaping () -> Void) { self.handler = handler }
        @objc func openScreenCaptureSettings() { handler() }
    }

    /// 文案逐字（spec §8.4 引文；测试自带字面量，避免实现常量自证）
    func testStatusLineAndNoticeTextsAreVerbatim() {
        XCTAssertEqual(ScreenCaptureReconfirmGuide.statusLineTitle, "屏幕录制权限需重新确认")
        XCTAssertEqual(
            ScreenCaptureReconfirmGuide.noticeText,
            "macOS 会定期要求重新确认屏幕录制权限。请在系统设置中重新打开开关，然后重启应用。"
        )
    }

    /// 状态行可点（挂目标与动作），说明行置灰无动作
    func testMenuItemsAvailability() {
        let target = ActionTarget(handler: {})
        let items = ScreenCaptureReconfirmGuide.menuItems(statusLineTarget: target,
                                                         action: #selector(ActionTarget.openScreenCaptureSettings))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, ScreenCaptureReconfirmGuide.statusLineTitle)
        XCTAssertTrue(items[0].isEnabled)
        XCTAssertEqual(items[0].action, #selector(ActionTarget.openScreenCaptureSettings))
        XCTAssertEqual(items[0].target as? ActionTarget, target)

        XCTAssertEqual(items[1].title, ScreenCaptureReconfirmGuide.noticeText)
        XCTAssertFalse(items[1].isEnabled)
        XCTAssertNil(items[1].action)
    }

    /// 拼接：替换占位菜单的状态行（索引 0），说明行插其后，其余结构原样保留
    func testInstallReplacesPlaceholderStatusLineAndKeepsRest() {
        let menu = PlaceholderMenu.build()
        let target = ActionTarget(handler: {})
        ScreenCaptureReconfirmGuide.install(into: menu, statusLineTarget: target,
                                            action: #selector(ActionTarget.openScreenCaptureSettings))

        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles, [
            "屏幕录制权限需重新确认",
            "macOS 会定期要求重新确认屏幕录制权限。请在系统设置中重新打开开关，然后重启应用。",
            "立即恢复",
            "撤销上次恢复",
            "登录时启动",
            "打开快照文件夹",
            "打开日志文件夹",
            "能力状态（占位）",
            "退出窗口布局恢复器",
        ])

        // 状态行仍是最顶部项（原「状态行（占位）」被移除，不再出现）
        XCTAssertFalse(titles.contains("状态行（占位）"))
        XCTAssertEqual(menu.items.first?.isEnabled, true)
    }
}
