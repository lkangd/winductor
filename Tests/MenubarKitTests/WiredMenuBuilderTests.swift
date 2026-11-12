import AppKit
import XCTest
@testable import MenubarKit

final class WiredMenuBuilderTests: XCTestCase {
    private var calls: [String] = []
    private func content(available: Bool = true, entries: Bool = true, wired: Bool = true) -> WiredMenuContent {
        WiredMenuContent(statusLineTitle: "状态", canSavePreset: available,
            restorePresets: entries ? [.init(id: "a", name: "工作", isAuto: true), .init(id: "b", name: "家", isAuto: false)] : [],
            canUndo: available, capabilityTitle: "能力",
            onSavePreset: wired ? { self.calls.append("save") } : nil,
            onRestorePreset: wired ? { self.calls.append("restore:\($0)") } : nil,
            onUndo: { self.calls.append("undo") },
            onManagePresets: wired ? { self.calls.append("manage") } : nil,
            canOverwritePreset: available,
            onOverwritePreset: wired ? { self.calls.append("overwrite:\($0)") } : nil,
            onOpenSettings: wired ? { self.calls.append("settings") } : nil)
    }
    private func click(_ item: NSMenuItem?) throws {
        let item = try XCTUnwrap(item)
        XCTAssertTrue(item.isEnabled)
        _ = item.target?.perform(try XCTUnwrap(item.action), with: item)
    }
    func testMenuTreeAndSeparators() throws {
        let menu = WiredMenuBuilder.build(content())
        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertEqual(menu.items.map(\.title), ["状态", "", "保存预设", "恢复预设", "撤销上次恢复", "", "管理预设…", "设置", "", "能力", "", "退出 Winductor"])
        XCTAssertEqual(menu.items.map(\.isSeparatorItem), [false, true, false, false, false, true, false, false, true, false, true, false])
        let save = try XCTUnwrap(menu.item(withTitle: "保存预设")?.submenu)
        XCTAssertFalse(save.autoenablesItems)
        XCTAssertEqual(save.items.map(\.title), ["保存新预设", "覆盖预设"])
        XCTAssertEqual(save.item(withTitle: "覆盖预设")?.submenu?.items.map(\.title), ["工作（自动）", "家"])
        XCTAssertEqual(menu.item(withTitle: "恢复预设")?.submenu?.items.map(\.title), ["工作（自动）", "家"])
        for title in ["状态", "能力"] {
            XCTAssertEqual(menu.item(withTitle: title)?.isEnabled, false)
            XCTAssertNil(menu.item(withTitle: title)?.action)
        }
        XCTAssertEqual(menu.items.last?.action, NSSelectorFromString("terminate:"))
        XCTAssertEqual(menu.items.last?.keyEquivalent, "q")
    }
    func testEveryActionRoutesIndependently() throws {
        let menu = WiredMenuBuilder.build(content())
        let save = try XCTUnwrap(menu.item(withTitle: "保存预设")?.submenu)
        try click(save.item(withTitle: "保存新预设"))
        try click(save.item(withTitle: "覆盖预设")?.submenu?.items[1])
        try click(menu.item(withTitle: "恢复预设")?.submenu?.items[0])
        try click(menu.item(withTitle: "撤销上次恢复"))
        try click(menu.item(withTitle: "管理预设…"))
        try click(menu.item(withTitle: "设置"))
        XCTAssertEqual(calls, ["save", "overwrite:b", "restore:a", "undo", "manage", "settings"])
    }
    func testSaveParentRemainsExpandableWhenBothChildrenUnavailable() throws {
        let menu = WiredMenuBuilder.build(content(available: false))
        let parent = try XCTUnwrap(menu.item(withTitle: "保存预设"))
        XCTAssertTrue(parent.isEnabled)
        let children = try XCTUnwrap(parent.submenu).items
        XCTAssertTrue(children.allSatisfy { !$0.isEnabled && $0.action == nil && $0.submenu == nil })
        XCTAssertEqual(menu.item(withTitle: "撤销上次恢复")?.isEnabled, false)
    }
    func testNoCurrentPresetsDisablesOverwriteAndRestoreButNotNewSave() throws {
        let menu = WiredMenuBuilder.build(content(entries: false))
        let save = try XCTUnwrap(menu.item(withTitle: "保存预设")?.submenu)
        XCTAssertEqual(save.item(withTitle: "覆盖预设")?.isEnabled, false)
        XCTAssertNil(save.item(withTitle: "覆盖预设")?.submenu)
        XCTAssertEqual(save.item(withTitle: "保存新预设")?.isEnabled, true)
        XCTAssertEqual(menu.item(withTitle: "恢复预设")?.isEnabled, false)
    }
    func testUnwiredCallbacksDisableActionsSafely() throws {
        let menu = WiredMenuBuilder.build(content(wired: false))
        let save = try XCTUnwrap(menu.item(withTitle: "保存预设")?.submenu)
        for item in save.items + [menu.item(withTitle: "恢复预设")!, menu.item(withTitle: "管理预设…")!, menu.item(withTitle: "设置")!] {
            XCTAssertFalse(item.isEnabled)
            XCTAssertNil(item.action)
            XCTAssertNil(item.submenu)
        }
    }
}
