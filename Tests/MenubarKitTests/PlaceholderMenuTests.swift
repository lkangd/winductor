import AppKit
import XCTest
@testable import MenubarKit

// 票 10 → 票 06：未就绪态占位菜单骨架（结构随 display-presets spec §6.1 菜单）。
// 接缝：PlaceholderMenu.build() 的公开产物——菜单结构与项的可用性。
// 独立事实来源：spec §6.1 的定稿菜单（状态行 + 动作项骨架 + 分隔线位置 + 退出）。
final class PlaceholderMenuTests: XCTestCase {
    private func makeMenu() -> NSMenu { PlaceholderMenu.build() }

    /// 结构：非分隔线项的标题与顺序必须与 spec §6.1 骨架逐字一致
    func testStructureMatchesSpec61Skeleton() {
        let titles = makeMenu().items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles, [
            "状态行（占位）",
            "保存当前布局为预设…",
            "恢复预设",
            "撤销上次恢复",
            "管理预设…",
            "登录时启动",
            "打开预设文件夹",
            "打开日志文件夹",
            "能力状态（占位）",
            "退出 Winductor",
        ])
    }

    /// 分隔线位置：状态行后、恢复组后、管理预设后、设置组后、能力状态后（spec §6.1 的五条 ──────────）
    func testSeparatorsMatchSpec61Layout() {
        let flags = makeMenu().items.map(\.isSeparatorItem)
        XCTAssertEqual(flags, [
            false, true, // 状态行 ────
            false, false, false, true, // 保存/恢复预设/撤销上次恢复 ────
            false, true, // 管理预设… ────
            false, false, false, true, // 登录时启动/预设/日志 ────
            false, true, // 能力状态（占位） ────
            false, // 退出
        ])
    }

    /// 骨架占位项（引擎/设置未接线）一律置灰且不挂动作
    func testPlaceholderItemsAreDisabledWithoutAction() {
        for item in makeMenu().items
        where !item.isSeparatorItem && item.title != "退出 Winductor" {
            XCTAssertFalse(item.isEnabled, "占位项应置灰：\(item.title)")
            XCTAssertNil(item.action, "占位项不应挂动作：\(item.title)")
        }
    }

    /// 「退出 Winductor」必须真实可用（骨架期唯一活项），走 Cocoa terminate: 响应链
    func testQuitItemIsEnabledWithTerminateAction() {
        let quit = makeMenu().items.last
        XCTAssertEqual(quit?.title, "退出 Winductor")
        XCTAssertTrue(quit?.isEnabled ?? false)
        XCTAssertEqual(quit?.action, NSSelectorFromString("terminate:"))
    }
}
