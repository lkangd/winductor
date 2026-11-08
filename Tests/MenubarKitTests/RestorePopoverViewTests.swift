import AppKit
import XCTest
@testable import MenubarKit

// RestorePopoverViewTests — popover 内容视图的薄层验收：显示的文本与按钮、点击回传的事件。
// 接缝：RestorePromptView / AutoRestoreNoticeView（由视图模型构造，按钮 target/action 与真实点击同路径）。
final class RestorePopoverViewTests: XCTestCase {
    private var events: [RestorePopoverEvent] = []

    override func setUp() { events = [] }

    private func option(_ id: String, _ name: String, summary: [String], shortage: [String] = []) -> RestorePromptOption {
        RestorePromptOption(presetID: id, name: name, summaryLines: summary, shortageLines: shortage)
    }

    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { sub -> [NSButton] in
            (sub as? NSButton).map { [$0] } ?? buttons(in: sub)
        }
    }

    private func texts(in view: NSView) -> [String] {
        view.subviews.flatMap { sub -> [String] in
            if let label = sub as? NSTextField { return sub.isHidden ? [] : [label.stringValue] }
            return sub.isHidden ? [] : texts(in: sub)
        }
    }

    private func click(_ title: String, in view: NSView) {
        guard let button = buttons(in: view).first(where: { $0.title == title }) else {
            return XCTFail("缺按钮：\(title)")
        }
        button.performClick(nil)
    }

    private var prompt: RestorePromptContent {
        RestorePromptContent(topologyKey: "k", title: "家里",
                             options: [option("p1", "工作", summary: ["DELL：2 个应用 · 3 个窗口"]),
                                       option("p2", "演示", summary: ["DELL：无窗口"],
                                              shortage: ["屏幕「DELL」当前 Space 比预设少 1 个，多出的窗口将合并"])],
                             selectedPresetID: "p2")
    }

    /// 多预设：拓扑名 + 单选（默认项选中）+ 所选预设摘要与 Space 不足；点单选/恢复/忽略回传事件
    func testPromptViewShowsSelectionDetailAndForwardsClicks() {
        let view = RestorePromptView(content: prompt) { [unowned self] in self.events.append($0) }

        XCTAssertTrue(texts(in: view).contains("家里"))
        XCTAssertTrue(texts(in: view).contains("DELL：无窗口"))
        XCTAssertTrue(texts(in: view).contains("屏幕「DELL」当前 Space 比预设少 1 个，多出的窗口将合并"))
        XCTAssertEqual(buttons(in: view).first { $0.title == "演示" }?.state, .on)

        click("工作", in: view)
        click("恢复", in: view)
        click("忽略", in: view)
        XCTAssertEqual(events, [.select(presetID: "p1"), .restoreTapped, .ignoreTapped])

        var reselected = prompt
        reselected.selectedPresetID = "p1"
        view.update(reselected)
        XCTAssertTrue(texts(in: view).contains("DELL：2 个应用 · 3 个窗口"))
        XCTAssertFalse(texts(in: view).contains("DELL：无窗口"))
    }

    /// 单预设：不出单选，直接显示预设名
    func testSinglePresetPromptHasNoRadio() {
        let single = RestorePromptContent(topologyKey: "k", title: "家里",
                                          options: [option("p1", "工作", summary: [])], selectedPresetID: "p1")
        let view = RestorePromptView(content: single) { _ in }

        XCTAssertNil(buttons(in: view).first { $0.title == "工作" })
        XCTAssertTrue(texts(in: view).contains("预设：工作"))
    }

    /// 告知：标题 + 计数行；撤销 / 改用其他预设… 按标志出现并回传事件
    func testNoticeViewButtonsFollowFlags() {
        let content = AutoRestoreNoticeContent(topologyKey: "k", headline: "已按「工作」恢复",
                                               detail: "3 窗口归位、0 跳过、0 失败",
                                               showsUndo: true, showsSwitchPreset: true)
        let view = AutoRestoreNoticeView(content: content) { [unowned self] in self.events.append($0) }

        XCTAssertTrue(texts(in: view).contains("已按「工作」恢复"))
        XCTAssertTrue(texts(in: view).contains("3 窗口归位、0 跳过、0 失败"))
        click("撤销", in: view)
        click("改用其他预设…", in: view)
        XCTAssertEqual(events, [.undoTapped, .switchPresetTapped])

        let bare = AutoRestoreNoticeView(content: AutoRestoreNoticeContent(
            topologyKey: "k", headline: "按「工作」恢复失败", detail: "x",
            showsUndo: false, showsSwitchPreset: false)) { _ in }
        XCTAssertEqual(buttons(in: bare).map(\.title), [])
    }
}
