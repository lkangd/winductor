import XCTest
@testable import MenubarKit

// display-presets 票 06：菜单状态行四态（display-presets spec §6.1）。
// 接缝：StatusLineState 的公开判定入口——按当前屏数、镜像态、当前拓扑的预设数与自动预设名产出状态行标题。
// 独立事实来源：spec §6.1 逐字措辞（测试自带字面量，不用实现常量自证）。
final class StatusLineStateTests: XCTestCase {
    /// 有自动预设：「N 屏 · M 个预设（自动：X）」（spec §6.1 示例原文）
    func testPresetsWithAutoShowCountAndAutoName() {
        XCTAssertEqual(StatusLineState.title(displayCount: 3, isMirrored: false, presetCount: 2, autoPresetName: "工作"),
                       "3 屏 · 2 个预设（自动：工作）")
    }

    /// 有预设无自动：「N 屏 · M 个预设」
    func testPresetsWithoutAutoShowCountOnly() {
        XCTAssertEqual(StatusLineState.title(displayCount: 2, isMirrored: false, presetCount: 1, autoPresetName: nil),
                       "2 屏 · 1 个预设")
    }

    /// 无预设：「N 屏 · 无预设」（单屏同口径，旧「一屏（拔出）」不再出现；N 用阿拉伯数字）
    func testNoPresetsShowsNoPresetWording() {
        XCTAssertEqual(StatusLineState.title(displayCount: 1, isMirrored: false, presetCount: 0, autoPresetName: nil),
                       "1 屏 · 无预设")
        XCTAssertEqual(StatusLineState.title(displayCount: 12, isMirrored: false, presetCount: 0, autoPresetName: nil),
                       "12 屏 · 无预设")
    }

    /// 任一屏处于镜像集合：「镜像中」，不论该拓扑有无预设（spec §3.3）
    func testMirroredOverridesPresetState() {
        XCTAssertEqual(StatusLineState.title(displayCount: 2, isMirrored: true, presetCount: 2, autoPresetName: "工作"),
                       "镜像中")
        XCTAssertEqual(StatusLineState.title(displayCount: 2, isMirrored: true, presetCount: 0, autoPresetName: nil),
                       "镜像中")
    }
}
