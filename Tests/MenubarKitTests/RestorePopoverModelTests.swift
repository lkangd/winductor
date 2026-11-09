import Core
import RestoreEngine
import XCTest
@testable import Core  // 构造 PresetTopology / Preset（memberwise init 为 internal）
@testable import MenubarKit

// RestorePopoverModelTests — 恢复提示与自动恢复告知的视图模型（display-presets spec §6.2/§6.3）。
// 接缝：RestorePromptContent.make / AutoRestoreNoticeContent.make（纯推导）与 RestorePopoverState（替换/收起规则）。
final class RestorePopoverModelTests: XCTestCase {
    private let screenA = "A-UUID"

    private func preset(_ id: String, _ name: String, userSpaces: Int = 1, windows: Int = 0,
                        isAuto: Bool = false) -> Preset {
        let snapshot = Snapshot(
            capturedAt: Date(timeIntervalSince1970: 0),
            topology: [TopologyDisplay(uuid: screenA, localizedName: "A",
                                       frame: SnapshotDisplayFrame(x: 0, y: 0, w: 1000, h: 800), orientation: 0)],
            spaces: (1...userSpaces).map {
                SnapshotSpace(displayUUID: screenA, index: $0, kind: .user, fullscreenAppBundleID: nil)
            },
            windows: (0..<windows).map {
                SnapshotWindow(bundleID: "app.\($0)", title: "", siblingIndex: 0, displayUUID: screenA,
                               spaceIndex: 1, x: 0, y: 0, w: 1, h: 1, minimized: false)
            })
        return Preset(id: id, name: name, savedAt: Date(timeIntervalSince1970: 0), isAuto: isAuto,
                      snapshot: snapshot)
    }

    private func topology(_ presets: [Preset], alias: String? = nil, lastRestored: String? = nil) -> PresetTopology {
        PresetTopology(key: "topo-1", canonicalDescription: "",
                       displays: [TopologyDisplayInfo(uuid: screenA, name: "DELL",
                                                      frame: SnapshotDisplayFrame(x: 0, y: 0, w: 1000, h: 800),
                                                      pixelWidth: 2000, pixelHeight: 1600, rotation: 0)],
                       alias: alias, presets: presets, lastRestoredPresetID: lastRestored)
    }

    // MARK: 恢复提示内容（§6.2）

    /// 默认选中最近恢复过的；否则最近保存的（presets 按保存时间升序 → 末项）；最近恢复指向已删预设时同「否则」
    func testPromptDefaultSelectionPrefersLastRestoredElseLatestSaved() throws {
        let presets = [preset("p1", "工作"), preset("p2", "演示"), preset("p3", "游戏")]

        XCTAssertEqual(RestorePromptContent.make(topology: topology(presets, lastRestored: "p1"),
                                                 currentSpaces: nil)?.selectedPresetID, "p1")
        XCTAssertEqual(RestorePromptContent.make(topology: topology(presets), currentSpaces: nil)?.selectedPresetID,
                       "p3")
        XCTAssertEqual(RestorePromptContent.make(topology: topology(presets, lastRestored: "gone"),
                                                 currentSpaces: nil)?.selectedPresetID, "p3")
    }

    /// 拓扑名别名优先；所选预设带摘要与 Space 不足提示（对比实时 Space）；仅一个预设不出单选
    func testPromptCarriesTitleSummaryAndSpaceShortage() throws {
        let live = [SpaceEntry(spaceID: 1, displayUUID: screenA, index: 1, kind: SpaceKind.user)]
        let single = try XCTUnwrap(RestorePromptContent.make(
            topology: topology([preset("p1", "工作", userSpaces: 3, windows: 2)], alias: "家里"),
            currentSpaces: live))

        XCTAssertEqual(single.title, "家里")
        XCTAssertFalse(single.showsPicker)
        XCTAssertEqual(single.selected?.name, "工作")
        XCTAssertEqual(single.selected?.summaryLines, ["DELL：2 个应用 · 2 个窗口"])
        XCTAssertEqual(single.selected?.shortageLines, ["屏幕「DELL」当前 Space 比预设少 2 个，多出的窗口将合并"])

        let multi = try XCTUnwrap(RestorePromptContent.make(
            topology: topology([preset("p1", "工作"), preset("p2", "演示")]), currentSpaces: live))
        XCTAssertEqual(multi.title, "DELL", "无别名 = 屏幕名组合")
        XCTAssertTrue(multi.showsPicker)
        XCTAssertEqual(multi.selected?.shortageLines, [])
    }

    /// 拓扑无预设：不构造提示
    func testPromptNotBuiltForTopologyWithoutPresets() {
        XCTAssertNil(RestorePromptContent.make(topology: topology([]), currentSpaces: nil))
    }

    // MARK: 自动恢复告知内容（§6.3）

    private func autoRestored(failure: String? = nil, degraded: [String] = [],
                              hasOtherPresets: Bool) -> AutoRestoredOutcome {
        AutoRestoredOutcome(topologyKey: "topo-1", presetID: "p1", presetName: "工作",
                            notice: RestoreCompletionNotice(trigger: .auto, okCount: 12, skipCount: 1, failCount: 0,
                                                            degradedLayerNames: degraded, failureDetail: failure),
                            hasOtherPresets: hasOtherPresets)
    }

    /// 「已按『X』恢复」+ 计数与降级附注（口径同完成通知）+ 撤销；有其他预设才附「改用其他预设…」
    func testNoticeHeadlineCountsUndoAndSwitchEntry() {
        let notice = AutoRestoreNoticeContent.make(autoRestored(degraded: ["Space 归属"], hasOtherPresets: true))

        XCTAssertEqual(notice.headline, "已按『工作』恢复")
        // 计数与降级附注分两行呈现（票 14），合起来仍是完成通知的口径
        XCTAssertEqual(notice.detail, "12 窗口归位、1 跳过、0 失败")
        XCTAssertEqual(notice.degradeNote, "本次 Space 归属层失效（几何已恢复）")
        XCTAssertTrue(notice.showsUndo)
        XCTAssertTrue(notice.showsSwitchPreset)

        let clean = AutoRestoreNoticeContent.make(autoRestored(hasOtherPresets: false))
        XCTAssertFalse(clean.showsSwitchPreset)
        XCTAssertNil(clean.degradeNote)
    }

    /// 票 17：全屏应用卡在其他屏 → 告知附注带可操作提示（无降级时单独成附注）
    func testNoticeCarriesFullscreenOnOtherDisplayHint() {
        let outcome = AutoRestoredOutcome(
            topologyKey: "topo-1", presetID: "p1", presetName: "工作",
            notice: RestoreCompletionNotice(trigger: .auto, okCount: 12, skipCount: 1, failCount: 0,
                                            degradedLayerNames: [], failureDetail: nil,
                                            fullscreenOnOtherDisplayCount: 1),
            hasOtherPresets: false)
        let notice = AutoRestoreNoticeContent.make(outcome)

        XCTAssertEqual(notice.detail, "12 窗口归位、1 跳过、0 失败")
        XCTAssertEqual(notice.degradeNote, "1 个全屏应用在其他屏幕上，退出全屏后可再次恢复")
    }

    /// 管线中止（无显示器 / 回滚快照写失败）：报失败原因，不给撤销
    func testNoticeForFailedAutoRestoreHasNoUndo() {
        let notice = AutoRestoreNoticeContent.make(autoRestored(failure: "无活动显示器", hasOtherPresets: true))

        XCTAssertEqual(notice.headline, "按『工作』恢复失败")
        XCTAssertEqual(notice.detail, "无活动显示器")
        XCTAssertNil(notice.degradeNote)
        XCTAssertFalse(notice.showsUndo)
        XCTAssertTrue(notice.showsSwitchPreset)
    }

    // MARK: 呈现状态（替换 / 收起 / 自动消失）

    private func prompt(_ key: String = "topo-1", presets: [Preset]? = nil) -> RestorePromptContent {
        RestorePromptContent.make(topology: PresetTopology(
            key: key, canonicalDescription: "", displays: [], alias: nil,
            presets: presets ?? [preset("p1", "工作"), preset("p2", "演示")], lastRestoredPresetID: nil),
                                  currentSpaces: nil)!
    }

    /// 拓扑再变：新提示替换旧提示（含正在显示的告知）；新拓扑无预设（dismiss）则收起
    func testNewOutcomeReplacesAndDismissCollapses() {
        var state = RestorePopoverState()
        state.apply(.promptNeeded(prompt("topo-1")))
        state.apply(.promptNeeded(prompt("topo-2")))
        XCTAssertEqual(state.presentation, .prompt(prompt("topo-2")))

        state.apply(.dismiss)
        XCTAssertEqual(state.presentation, .hidden)

        state.apply(.autoRestored(AutoRestoreNoticeContent.make(autoRestored(hasOtherPresets: true))))
        state.apply(.promptNeeded(prompt("topo-2")))
        XCTAssertEqual(state.presentation, .prompt(prompt("topo-2")), "告知被新拓扑的提示取代")
    }

    /// 「恢复」按当前单选执行并收起；「忽略」只收起；未知预设 id 的选择不生效
    func testPromptRestoreUsesSelectionAndIgnoreJustCollapses() {
        var state = RestorePopoverState()
        state.apply(.promptNeeded(prompt()))
        XCTAssertEqual(state.apply(.select(presetID: "p1")), [])
        state.apply(.select(presetID: "nope"))

        XCTAssertEqual(state.apply(.restoreTapped), [.restore(presetID: "p1", topologyKey: "topo-1")])
        XCTAssertEqual(state.presentation, .hidden)
        XCTAssertEqual(state.apply(.restoreTapped), [], "已收起后重复点击不再恢复")

        state.apply(.promptNeeded(prompt()))
        XCTAssertEqual(state.apply(.ignoreTapped), [])
        XCTAssertEqual(state.presentation, .hidden)
    }

    /// 告知：弹出即排定到期；只收起同一代告知（被替换后的旧到期不误收新内容）
    func testNoticeExpiresOnlyForItsOwnGeneration() {
        var state = RestorePopoverState()
        let notice = AutoRestoreNoticeContent.make(autoRestored(hasOtherPresets: true))
        XCTAssertEqual(state.apply(.autoRestored(notice)), [.scheduleNoticeExpiry(generation: 1)])
        XCTAssertEqual(state.apply(.autoRestored(notice)), [.scheduleNoticeExpiry(generation: 2)])

        state.apply(.noticeExpired(generation: 1))
        XCTAssertEqual(state.presentation, .notice(notice, generation: 2))
        state.apply(.noticeExpired(generation: 2))
        XCTAssertEqual(state.presentation, .hidden)

        state.apply(.promptNeeded(prompt()))
        state.apply(.noticeExpired(generation: 2))
        XCTAssertEqual(state.presentation, .prompt(prompt()), "到期不收起恢复提示（提示不自动消失）")
    }

    /// 告知「撤销」走撤销管线并收起；「改用其他预设…」请协调器按该拓扑打开恢复提示
    func testNoticeUndoAndSwitchPresetEffects() {
        var state = RestorePopoverState()
        state.apply(.autoRestored(AutoRestoreNoticeContent.make(autoRestored(hasOtherPresets: true))))
        XCTAssertEqual(state.apply(.switchPresetTapped), [.openPrompt(topologyKey: "topo-1")])

        state.apply(.autoRestored(AutoRestoreNoticeContent.make(autoRestored(hasOtherPresets: true))))
        XCTAssertEqual(state.apply(.undoTapped), [.undo])
        XCTAssertEqual(state.presentation, .hidden)
        XCTAssertEqual(state.apply(.undoTapped), [], "已收起后重复点击不再撤销")

        state.apply(.autoRestored(AutoRestoreNoticeContent.make(autoRestored(failure: "x", hasOtherPresets: false))))
        XCTAssertEqual(state.apply(.undoTapped), [], "失败告知无撤销")
        XCTAssertEqual(state.apply(.switchPresetTapped), [], "无其他预设时无入口")
    }
}
