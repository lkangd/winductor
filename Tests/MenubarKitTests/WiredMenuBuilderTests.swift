import AppKit
import XCTest
@testable import MenubarKit

// 票 19：全量菜单构建（spec §8.2 七项定稿结构 + §8.5 能力状态行）。
// 接缝：WiredMenuBuilder.build(WiredMenuContent) 的公开产物——菜单结构、逐字文案、
//       勾选/禁用态与动作路由（经 NSObject target/action 路由到注入闭包，测试直接 perform 捕获）。
// 独立事实来源：spec §8.2 定稿菜单（09 二）逐字。
final class WiredMenuBuilderTests: XCTestCase {
    private var calls: [String] = []

    override func setUp() {
        calls = []
    }

    private func record(_ name: String) { calls.append(name) }

    private func makeContent(canUndo: Bool = true, loginChecked: Bool = false,
                             capabilityTitle: String = "能力状态：全部可用",
                             statusLineTitle: String = "三屏 · 快照就绪") -> WiredMenuContent {
        WiredMenuContent(
            statusLineTitle: statusLineTitle,
            canUndo: canUndo,
            loginLaunchChecked: loginChecked,
            capabilityTitle: capabilityTitle,
            onRestoreNow: { [unowned self] in record("restoreNow") },
            onUndo: { [unowned self] in record("undo") },
            onToggleLoginLaunch: { [unowned self] in record("toggleLogin") },
            onOpenSnapshotsFolder: { [unowned self] in record("openSnapshots") },
            onOpenLogsFolder: { [unowned self] in record("openLogs") })
    }

    private func makeMenu(content: WiredMenuContent) -> NSMenu { WiredMenuBuilder.build(content) }

    private func item(_ menu: NSMenu, titled title: String) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    /// 结构与全部文案：非分隔线项标题与顺序必须与 spec §8.2 定稿逐字一致（无「（占位）」后缀）
    func testStructureAndTitlesMatchSpec82() {
        let menu = makeMenu(content: makeContent())
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), [
            "三屏 · 快照就绪",   // 状态行（动态产出，示例取 §8.2 验收拓扑原文）
            "立即恢复",
            "撤销上次恢复",
            "登录时启动",
            "打开快照文件夹",
            "打开日志文件夹",
            "能力状态：全部可用",
            "退出 Winductor",
        ])
    }

    /// 分隔线位置：状态行后、恢复组后、设置组后、能力状态行后（spec §8.2 四条 ──────────）
    func testSeparatorLayoutMatchesSpec82() {
        let flags = makeMenu(content: makeContent()).items.map(\.isSeparatorItem)
        XCTAssertEqual(flags, [
            false, true,          // 状态行 ────
            false, false, true,   // 立即恢复／撤销上次恢复 ────
            false, false, false, true,  // 登录时启动／快照文件夹／日志文件夹 ────
            false, true,          // 能力状态行 ────
            false,                // 退出
        ])
    }

    /// 状态行与能力状态行是纯文本：置灰、不挂动作（spec §8.2「状态行（纯文本）」/ §8.5 呈现行）
    func testStatusAndCapabilityLinesAreDisabledText() {
        let menu = makeMenu(content: makeContent(capabilityTitle: "能力状态：以下恢复层不可用：Space 归属（详见日志）",
                                                 statusLineTitle: "三屏 · 无匹配快照"))
        for title in ["三屏 · 无匹配快照", "能力状态：以下恢复层不可用：Space 归属（详见日志）"] {
            let line = item(menu, titled: title)
            XCTAssertNotNil(line, title)
            XCTAssertEqual(line?.isEnabled, false, title)
            XCTAssertNil(line?.action, title)
        }
    }

    /// 「立即恢复」可用且动作路由到注入闭包
    func testRestoreNowItemRoutesAction() {
        let menu = makeMenu(content: makeContent())
        let restore = item(menu, titled: "立即恢复")
        XCTAssertEqual(restore?.isEnabled, true)
        restore?.target?.perform(restore!.action!, with: restore)
        XCTAssertEqual(calls, ["restoreNow"])
    }

    /// 「撤销上次恢复」可用性随 canUndo：可撤销时可用且路由；不可撤销时置灰无动作（spec §7.4 入口禁用）
    func testUndoItemAvailabilityFollowsCanUndo() {
        let undoable = item(makeMenu(content: makeContent(canUndo: true)), titled: "撤销上次恢复")
        XCTAssertEqual(undoable?.isEnabled, true)
        undoable?.target?.perform(undoable!.action!, with: undoable)
        XCTAssertEqual(calls, ["undo"])

        calls = []
        let notUndoable = item(makeMenu(content: makeContent(canUndo: false)), titled: "撤销上次恢复")
        XCTAssertEqual(notUndoable?.isEnabled, false)
        XCTAssertNil(notUndoable?.action)
    }

    /// 「登录时启动」勾选态（spec §8.2「登录时启动 ✓」= NSMenuItem.state）且切换动作可路由
    func testLoginLaunchCheckboxStateAndToggle() {
        let checked = item(makeMenu(content: makeContent(loginChecked: true)), titled: "登录时启动")
        XCTAssertEqual(checked?.isEnabled, true)
        XCTAssertEqual(checked?.state, NSControl.StateValue.on)

        let unchecked = item(makeMenu(content: makeContent(loginChecked: false)), titled: "登录时启动")
        XCTAssertEqual(unchecked?.state, NSControl.StateValue.off)

        unchecked?.target?.perform(unchecked!.action!, with: unchecked)
        XCTAssertEqual(calls, ["toggleLogin"])
    }

    /// 两个 Finder 入口可用且分别路由（spec 09 四：应用内零管理界面，直达目录）
    func testFinderItemsRouteDistinctActions() {
        let menu = makeMenu(content: makeContent())
        item(menu, titled: "打开快照文件夹")?.target?.perform(
            item(menu, titled: "打开快照文件夹")!.action!, with: nil)
        item(menu, titled: "打开日志文件夹")?.target?.perform(
            item(menu, titled: "打开日志文件夹")!.action!, with: nil)
        XCTAssertEqual(calls, ["openSnapshots", "openLogs"])
    }

    /// 「退出 Winductor」可用，走 Cocoa terminate: 响应链（spec §8.2 退出项）
    func testQuitItemEnabledWithTerminateAction() {
        let quit = item(makeMenu(content: makeContent()), titled: "退出 Winductor")
        XCTAssertEqual(quit?.isEnabled, true)
        XCTAssertEqual(quit?.action, NSSelectorFromString("terminate:"))
        XCTAssertEqual(quit?.keyEquivalent, "q")
    }
}
