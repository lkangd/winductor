import AppKit
import XCTest
@testable import MenubarKit

// 票 10：占位菜单骨架测试（spec §8.2 结构，票 19 全量接线前的合同）。
// 接缝：PlaceholderMenu.build() 的公开产物——菜单结构与项的可用性。
// 独立事实来源：spec §8.2 的定稿菜单（状态行 + 七项骨架 + 分隔线位置 + 退出）。
final class PlaceholderMenuTests: XCTestCase {
    private func makeMenu() -> NSMenu { PlaceholderMenu.build() }

    /// 结构：非分隔线项的标题与顺序必须与 spec §8.2 骨架逐字一致
    func testStructureMatchesSpec82Skeleton() {
        let titles = makeMenu().items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles, [
            "状态行（占位）",
            "立即恢复",
            "撤销上次恢复",
            "登录时启动",
            "打开快照文件夹",
            "打开日志文件夹",
            "能力状态（占位）",
            "退出窗口布局恢复器",
        ])
    }

    /// 分隔线位置：状态行后、恢复组后、设置组后、能力状态后（spec §8.2 的四条 ──────────）
    func testSeparatorsMatchSpec82Layout() {
        let flags = makeMenu().items.map(\.isSeparatorItem)
        XCTAssertEqual(flags, [
            false, true, // 状态行 ────
            false, false, true, // 立即恢复/撤销上次恢复 ────
            false, false, false, true, // 登录时启动/快照/日志 ────
            false, true, // 能力状态（占位） ────
            false, // 退出
        ])
    }

    /// 骨架占位项（引擎/设置未接线）一律置灰且不挂动作
    func testPlaceholderItemsAreDisabledWithoutAction() {
        for item in makeMenu().items
        where !item.isSeparatorItem && item.title != "退出窗口布局恢复器" {
            XCTAssertFalse(item.isEnabled, "占位项应置灰：\(item.title)")
            XCTAssertNil(item.action, "占位项不应挂动作：\(item.title)")
        }
    }

    /// 「退出窗口布局恢复器」必须真实可用（骨架期唯一活项），走 Cocoa terminate: 响应链
    func testQuitItemIsEnabledWithTerminateAction() {
        let quit = makeMenu().items.last
        XCTAssertEqual(quit?.title, "退出窗口布局恢复器")
        XCTAssertTrue(quit?.isEnabled ?? false)
        XCTAssertEqual(quit?.action, NSSelectorFromString("terminate:"))
    }
}
