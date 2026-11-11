import AppKit
import XCTest
@testable import MenubarKit

final class PlaceholderMenuTests: XCTestCase {
    func testPlaceholderUsesRefreshedTreeWithSafeDisabledActions() throws {
        let menu = PlaceholderMenu.build()
        XCTAssertEqual(menu.items.map(\.title), ["状态行（占位）", "", "保存预设", "恢复预设", "撤销上次恢复", "", "管理预设…", "设置", "", "能力状态（占位）", "", "退出 Winductor"])
        let save = try XCTUnwrap(menu.item(withTitle: "保存预设"))
        XCTAssertTrue(save.isEnabled)
        XCTAssertEqual(save.submenu?.items.map(\.title), ["保存新预设", "覆盖预设"])
        let disabled = menu.items.filter { !$0.isSeparatorItem && $0.title != "退出 Winductor" && $0.title != "保存预设" } + save.submenu!.items
        for item in disabled {
            XCTAssertFalse(item.isEnabled, item.title)
            XCTAssertNil(item.action, item.title)
        }
        XCTAssertTrue(menu.items.last!.isEnabled)
        XCTAssertEqual(menu.items.last?.action, NSSelectorFromString("terminate:"))
    }
    func testSettingsIsAvailableAndRoutesWithoutEnablingPresetActions() throws {
        var opened = 0
        let menu = PlaceholderMenu.build(onOpenSettings: { opened += 1 })
        let settings = try XCTUnwrap(menu.item(withTitle: "设置"))
        XCTAssertTrue(settings.isEnabled)
        _ = settings.target?.perform(try XCTUnwrap(settings.action), with: settings)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(menu.item(withTitle: "恢复预设")?.isEnabled, false)
        XCTAssertTrue(menu.item(withTitle: "保存预设")!.submenu!.items.allSatisfy { !$0.isEnabled })
    }
}
