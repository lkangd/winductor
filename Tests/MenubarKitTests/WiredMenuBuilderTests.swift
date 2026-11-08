import AppKit
import XCTest
@testable import MenubarKit

// 票 06：全量菜单构建（display-presets spec §6.1；取代票 19 的 spec §8.2 七项口径）。
// 接缝：WiredMenuBuilder.build(WiredMenuContent) 的公开产物——菜单结构、逐字文案、
//       勾选/禁用态、「恢复预设 ▸」子菜单与动作路由（经 NSObject target/action 路由到注入闭包，测试直接 perform 捕获）。
// 独立事实来源：spec §6.1 定稿菜单逐字。
final class WiredMenuBuilderTests: XCTestCase {
    private var calls: [String] = []

    override func setUp() {
        calls = []
    }

    private func record(_ name: String) { calls.append(name) }

    private func makeContent(statusLineTitle: String = "3 屏 · 2 个预设（自动：工作）",
                             canSavePreset: Bool = true,
                             restorePresets: [RestorePresetMenuEntry] = [
                                 RestorePresetMenuEntry(id: "p-home", name: "家", isAuto: false),
                                 RestorePresetMenuEntry(id: "p-work", name: "工作", isAuto: true),
                             ],
                             canUndo: Bool = true,
                             managePresetsAvailable: Bool = true,
                             loginChecked: Bool = false,
                             capabilityTitle: String = "能力状态：全部可用",
                             overwriteWired: Bool = false,
                             canOverwritePreset: Bool = true) -> WiredMenuContent {
        WiredMenuContent(
            statusLineTitle: statusLineTitle,
            canSavePreset: canSavePreset,
            restorePresets: restorePresets,
            canUndo: canUndo,
            loginLaunchChecked: loginChecked,
            capabilityTitle: capabilityTitle,
            onSavePreset: { [unowned self] in record("savePreset") },
            onRestorePreset: { [unowned self] id in record("restore:\(id)") },
            onUndo: { [unowned self] in record("undo") },
            onManagePresets: managePresetsAvailable ? { [unowned self] in record("managePresets") } : nil,
            onToggleLoginLaunch: { [unowned self] in record("toggleLogin") },
            onOpenPresetsFolder: { [unowned self] in record("openPresets") },
            onOpenLogsFolder: { [unowned self] in record("openLogs") },
            canOverwritePreset: canOverwritePreset,
            onOverwritePreset: overwriteWired ? { [unowned self] id in record("overwrite:\(id)") } : nil)
    }

    private func makeMenu(content: WiredMenuContent) -> NSMenu { WiredMenuBuilder.build(content) }

    private func item(_ menu: NSMenu, titled title: String) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    private func click(_ item: NSMenuItem?) {
        guard let item, let action = item.action else { return XCTFail("项不可点：\(item?.title ?? "nil")") }
        _ = item.target?.perform(action, with: item)
    }

    /// 结构与全部文案：非分隔线项标题与顺序必须与 spec §6.1 定稿逐字一致；「立即恢复」与「打开快照文件夹」已删
    func testStructureAndTitlesMatchSpec61() {
        let menu = makeMenu(content: makeContent())
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), [
            "3 屏 · 2 个预设（自动：工作）",   // 状态行（动态产出，示例取 §6.1 原文）
            "保存当前布局为预设…",
            "恢复预设",
            "撤销上次恢复",
            "管理预设…",
            "登录时启动",
            "打开预设文件夹",
            "打开日志文件夹",
            "能力状态：全部可用",
            "退出 Winductor",
        ])
    }

    /// 分隔线位置：状态行后、恢复组后、管理预设后、设置组后、能力状态行后（spec §6.1 五条 ──────────）
    func testSeparatorLayoutMatchesSpec61() {
        let flags = makeMenu(content: makeContent()).items.map(\.isSeparatorItem)
        XCTAssertEqual(flags, [
            false, true,                // 状态行 ────
            false, false, false, true,  // 保存当前布局为预设…／恢复预设 ▸／撤销上次恢复 ────
            false, true,                // 管理预设… ────
            false, false, false, true,  // 登录时启动／预设文件夹／日志文件夹 ────
            false, true,                // 能力状态行 ────
            false,                      // 退出
        ])
    }

    /// 状态行与能力状态行是纯文本：置灰、不挂动作
    func testStatusAndCapabilityLinesAreDisabledText() {
        let menu = makeMenu(content: makeContent(statusLineTitle: "镜像中",
                                                 capabilityTitle: "能力状态：以下恢复层不可用：Space 归属（详见日志）"))
        for title in ["镜像中", "能力状态：以下恢复层不可用：Space 归属（详见日志）"] {
            let line = item(menu, titled: title)
            XCTAssertNotNil(line, title)
            XCTAssertEqual(line?.isEnabled, false, title)
            XCTAssertNil(line?.action, title)
        }
    }

    /// 「保存当前布局为预设…」：可用时路由到注入闭包；不可用（未就绪/镜像中/恢复中）置灰无动作
    func testSavePresetItemAvailabilityAndRouting() {
        let available = item(makeMenu(content: makeContent(canSavePreset: true)), titled: "保存当前布局为预设…")
        XCTAssertEqual(available?.isEnabled, true)
        click(available)
        XCTAssertEqual(calls, ["savePreset"])

        let disabled = item(makeMenu(content: makeContent(canSavePreset: false)), titled: "保存当前布局为预设…")
        XCTAssertEqual(disabled?.isEnabled, false)
        XCTAssertNil(disabled?.action)
    }

    /// 「恢复预设 ▸」子菜单：按给定顺序列出当前拓扑预设，自动预设带「（自动）」标记；点击按预设 id 路由
    func testRestorePresetSubmenuListsPresetsWithAutoMarkerAndRoutesByID() throws {
        let parent = try XCTUnwrap(item(makeMenu(content: makeContent()), titled: "恢复预设"))
        XCTAssertEqual(parent.isEnabled, true)
        let submenu = try XCTUnwrap(parent.submenu)
        XCTAssertEqual(submenu.items.map(\.title), ["家", "工作（自动）"])
        XCTAssertTrue(submenu.items.allSatisfy(\.isEnabled))

        click(submenu.items[1])
        click(submenu.items[0])
        XCTAssertEqual(calls, ["restore:p-work", "restore:p-home"])
    }

    /// 「恢复预设 ▸」末尾「用当前布局覆盖 ▸」（spec §4.3，票 07）：预设列表后分隔线 + 同序预设子菜单，按 id 路由
    func testOverwriteSubmenuFollowsRestoreEntriesAndRoutesByID() throws {
        let submenu = try XCTUnwrap(item(makeMenu(content: makeContent(overwriteWired: true)), titled: "恢复预设")?.submenu)
        XCTAssertEqual(submenu.items.map(\.isSeparatorItem), [false, false, true, false])
        let overwrite = try XCTUnwrap(submenu.items.last)
        XCTAssertEqual(overwrite.title, "用当前布局覆盖")
        XCTAssertEqual(overwrite.isEnabled, true)
        let targets = try XCTUnwrap(overwrite.submenu)
        XCTAssertEqual(targets.items.map(\.title), ["家", "工作（自动）"])

        click(targets.items[1])
        XCTAssertEqual(calls, ["overwrite:p-work"])
    }

    /// 覆盖不可用（未就绪/镜像中/恢复中，与保存同口径）：「用当前布局覆盖」置灰，不挂子菜单
    func testOverwriteSubmenuDisabledWhenUnavailable() throws {
        let submenu = try XCTUnwrap(item(makeMenu(content: makeContent(overwriteWired: true, canOverwritePreset: false)),
                                         titled: "恢复预设")?.submenu)
        let overwrite = try XCTUnwrap(submenu.items.last)
        XCTAssertEqual(overwrite.title, "用当前布局覆盖")
        XCTAssertEqual(overwrite.isEnabled, false)
        XCTAssertNil(overwrite.submenu)
    }

    /// 无预设：「恢复预设」置灰（spec §6.1「无预设置灰」）
    func testRestorePresetDisabledWithoutPresets() {
        let parent = item(makeMenu(content: makeContent(restorePresets: [])), titled: "恢复预设")
        XCTAssertNotNil(parent)
        XCTAssertEqual(parent?.isEnabled, false)
    }

    /// 「撤销上次恢复」可用性随 canUndo：可撤销时可用且路由；不可撤销时置灰无动作
    func testUndoItemAvailabilityFollowsCanUndo() {
        let undoable = item(makeMenu(content: makeContent(canUndo: true)), titled: "撤销上次恢复")
        XCTAssertEqual(undoable?.isEnabled, true)
        click(undoable)
        XCTAssertEqual(calls, ["undo"])

        let notUndoable = item(makeMenu(content: makeContent(canUndo: false)), titled: "撤销上次恢复")
        XCTAssertEqual(notUndoable?.isEnabled, false)
        XCTAssertNil(notUndoable?.action)
    }

    /// 「管理预设…」：接了入口时可用且路由；未接（管理窗口未装配）时置灰
    func testManagePresetsItemRoutesWhenWired() {
        let wired = item(makeMenu(content: makeContent(managePresetsAvailable: true)), titled: "管理预设…")
        XCTAssertEqual(wired?.isEnabled, true)
        click(wired)
        XCTAssertEqual(calls, ["managePresets"])

        let unwired = item(makeMenu(content: makeContent(managePresetsAvailable: false)), titled: "管理预设…")
        XCTAssertEqual(unwired?.isEnabled, false)
        XCTAssertNil(unwired?.action)
    }

    /// 「登录时启动」勾选态（「登录时启动 ✓」= NSMenuItem.state）且切换动作可路由
    func testLoginLaunchCheckboxStateAndToggle() {
        let checked = item(makeMenu(content: makeContent(loginChecked: true)), titled: "登录时启动")
        XCTAssertEqual(checked?.isEnabled, true)
        XCTAssertEqual(checked?.state, NSControl.StateValue.on)

        let unchecked = item(makeMenu(content: makeContent(loginChecked: false)), titled: "登录时启动")
        XCTAssertEqual(unchecked?.state, NSControl.StateValue.off)

        click(unchecked)
        XCTAssertEqual(calls, ["toggleLogin"])
    }

    /// 两个 Finder 入口可用且分别路由
    func testFinderItemsRouteDistinctActions() {
        let menu = makeMenu(content: makeContent())
        click(item(menu, titled: "打开预设文件夹"))
        click(item(menu, titled: "打开日志文件夹"))
        XCTAssertEqual(calls, ["openPresets", "openLogs"])
    }

    /// 「退出 Winductor」可用，走 Cocoa terminate: 响应链
    func testQuitItemEnabledWithTerminateAction() {
        let quit = item(makeMenu(content: makeContent()), titled: "退出 Winductor")
        XCTAssertEqual(quit?.isEnabled, true)
        XCTAssertEqual(quit?.action, NSSelectorFromString("terminate:"))
        XCTAssertEqual(quit?.keyEquivalent, "q")
    }
}
