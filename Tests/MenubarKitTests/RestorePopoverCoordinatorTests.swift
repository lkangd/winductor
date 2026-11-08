import CoreGraphics
import Core
import RestoreEngine
import XCTest
@testable import MenubarKit

// RestorePopoverCoordinatorTests — 触发链判定结果 → popover 呈现与用户操作的接线（display-presets spec §6.2/§6.3）。
// 接缝：RestorePopoverCoordinator 公开入口（handle(outcome:) / 渲染器回传的用户操作），
// 观察假渲染器收到的呈现、注入的恢复/撤销闭包与到期调度。预设走真实 PresetStore 临时目录。
final class RestorePopoverCoordinatorTests: XCTestCase {
    private final class FakeRenderer: RestorePopoverRendering {
        var onEvent: ((RestorePopoverEvent) -> Void)?
        private(set) var rendered: [RestorePopoverPresentation] = []
        var last: RestorePopoverPresentation? { rendered.last }
        func render(_ presentation: RestorePopoverPresentation) { rendered.append(presentation) }
    }

    private var root: URL!
    private var store: PresetStore!
    private var renderer: FakeRenderer!
    private var restored: [(id: String, key: String)] = []
    /// 注入的手动恢复应答（nil = 受理）
    private var restoreRejection: ManualRestoreRejection?
    private var undoCalls = 0
    private var scheduled: [(delay: TimeInterval, fire: () -> Void)] = []
    private var liveSpaces: [SpaceEntry]?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("winductor-popover-\(UUID().uuidString)")
        store = PresetStore(directory: root)
        renderer = FakeRenderer()
        restored = []
        restoreRejection = nil
        undoCalls = 0
        scheduled = []
        liveSpaces = nil
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let screen = "S-UUID"

    private var observed: ObservedTopology {
        ObservedTopology(screens: [TopologyScreen(uuid: screen, name: "DELL",
                                                  frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                                                  pixelWidth: 2000, pixelHeight: 1600, rotation: 0, isMirrored: false)])
    }

    /// 存一个预设（快照含 userSpaces 个用户桌面、一个窗口）
    @discardableResult
    private func save(_ name: String, userSpaces: Int = 1) throws -> Preset {
        let snapshot = Snapshot(
            capturedAt: Date(),
            topology: [TopologyDisplay(uuid: screen, localizedName: "DELL",
                                       frame: SnapshotDisplayFrame(x: 0, y: 0, w: 1000, h: 800), orientation: 0)],
            spaces: (1...userSpaces).map {
                SnapshotSpace(displayUUID: screen, index: $0, kind: .user, fullscreenAppBundleID: nil)
            },
            windows: [SnapshotWindow(bundleID: "com.apple.Terminal", title: "", siblingIndex: 0, displayUUID: screen,
                                     spaceIndex: 1, x: 0, y: 0, w: 1, h: 1, minimized: false)])
        return try store.addPreset(name: name, snapshot: snapshot, topology: observed)
    }

    private var topology: PresetTopology { store.topology(key: observed.identity.key)! }

    private func makeCoordinator() -> RestorePopoverCoordinator {
        RestorePopoverCoordinator(
            renderer: renderer, presets: store,
            currentSpaces: { [unowned self] in self.liveSpaces },
            restorePreset: { [unowned self] id, key in
                self.restored.append((id, key))
                return self.restoreRejection
            },
            undo: { [unowned self] in self.undoCalls += 1 },
            scheduleAfter: { [unowned self] delay, fire in self.scheduled.append((delay, fire)) })
    }

    // MARK: 恢复提示

    /// 判定要提示 → 渲染提示（Space 不足对比实时清单）；点「恢复」→ 按所选预设走触发链手动恢复并收起
    func testPromptOutcomeRendersPromptAndRestoreRunsSelectedPreset() throws {
        try save("工作", userSpaces: 2)
        let latest = try save("演示", userSpaces: 2)
        liveSpaces = [SpaceEntry(spaceID: 1, displayUUID: screen, index: 1, kind: SpaceKind.user)]
        let coordinator = makeCoordinator()

        coordinator.handle(outcome: .promptNeeded(topology))

        guard case .prompt(let content)? = renderer.last else { return XCTFail("应渲染恢复提示") }
        XCTAssertEqual(content.selectedPresetID, latest.id, "从未恢复过 → 默认最近保存的")
        XCTAssertEqual(content.selected?.shortageLines, ["屏幕「DELL」当前 Space 比预设少 1 个，多出的窗口将合并"])

        renderer.onEvent?(.restoreTapped)
        XCTAssertEqual(restored.map(\.id), [latest.id])
        XCTAssertEqual(restored.map(\.key), [observed.identity.key])
        XCTAssertEqual(renderer.last, .hidden)
    }

    /// 新拓扑无预设 / 镜像中 / 未就绪 → 收起开着的提示
    func testDismissOutcomeCollapsesOpenPrompt() throws {
        try save("工作")
        let coordinator = makeCoordinator()
        coordinator.handle(outcome: .promptNeeded(topology))

        coordinator.handle(outcome: .dismissPrompt)

        XCTAssertEqual(renderer.last, .hidden)
    }

    /// 「恢复」因恢复进行中被拒：重新弹出同一提示（保留所选预设），选择不丢失（§6.2）
    func testRestoreRejectedWhileRestoringReshowsPromptWithSelection() throws {
        let work = try save("工作")
        try save("演示")
        let coordinator = makeCoordinator()
        coordinator.handle(outcome: .promptNeeded(topology))
        renderer.onEvent?(.select(presetID: work.id))
        restoreRejection = .restoreInProgress

        renderer.onEvent?(.restoreTapped)

        guard case .prompt(let content)? = renderer.last else { return XCTFail("被拒后应重新弹出提示") }
        XCTAssertEqual(content.selectedPresetID, work.id)
    }

    /// 「恢复」因拓扑已变被拒：提示属于旧拓扑，不再弹回
    func testRestoreRejectedForStaleTopologyStaysHidden() throws {
        try save("工作")
        let coordinator = makeCoordinator()
        coordinator.handle(outcome: .promptNeeded(topology))
        restoreRejection = .topologyChanged

        renderer.onEvent?(.restoreTapped)

        XCTAssertEqual(renderer.last, .hidden)
    }

    /// 拓扑再变（§6.2）：变化事件一到即收起旧提示，之后点「恢复」不生效
    func testTopologyChangingCollapsesStalePromptAndDisablesRestore() throws {
        try save("工作")
        let coordinator = makeCoordinator()
        coordinator.handle(outcome: .promptNeeded(topology))

        coordinator.handle(outcome: .topologyChanging)
        renderer.onEvent?(.restoreTapped)

        XCTAssertEqual(renderer.last, .hidden)
        XCTAssertTrue(restored.isEmpty, "旧拓扑的提示不再可点")
    }

    // MARK: 自动恢复告知

    private func autoRestored(_ preset: Preset, hasOtherPresets: Bool) -> TriggerOutcome {
        .autoRestored(AutoRestoredOutcome(
            topologyKey: observed.identity.key, presetID: preset.id, presetName: preset.name,
            notice: RestoreCompletionNotice(trigger: .auto, okCount: 3, skipCount: 0, failCount: 0,
                                            degradedLayerNames: [], failureDetail: nil),
            hasOtherPresets: hasOtherPresets))
    }

    /// 告知弹出后数秒自动消失；「撤销」走注入的撤销管线
    func testNoticeAutoDismissesAndUndoRunsUndoPipeline() throws {
        let work = try save("工作")
        let coordinator = makeCoordinator()

        coordinator.handle(outcome: autoRestored(work, hasOtherPresets: false))
        guard case .notice(let notice, _)? = renderer.last else { return XCTFail("应渲染自动恢复告知") }
        XCTAssertEqual(notice.headline, "已按『工作』恢复")
        XCTAssertEqual(scheduled.map(\.delay), [RestorePopoverCoordinator.noticeDuration])
        scheduled.first?.fire()
        XCTAssertEqual(renderer.last, .hidden)

        coordinator.handle(outcome: autoRestored(work, hasOtherPresets: false))
        renderer.onEvent?(.undoTapped)
        XCTAssertEqual(undoCalls, 1)
        XCTAssertEqual(renderer.last, .hidden)
    }

    /// 「改用其他预设…」→ 以该拓扑现存预设打开恢复提示，默认选中最近恢复的（刚自动恢复的那个）；不再自动消失
    func testSwitchPresetOpensPromptForTopology() throws {
        let work = try save("工作")
        try save("演示")
        try store.recordRestored(presetID: work.id, topologyKey: observed.identity.key)
        let coordinator = makeCoordinator()
        coordinator.handle(outcome: autoRestored(work, hasOtherPresets: true))

        renderer.onEvent?(.switchPresetTapped)

        guard case .prompt(let content)? = renderer.last else { return XCTFail("应换成恢复提示") }
        XCTAssertEqual(content.options.map(\.name), ["工作", "演示"])
        XCTAssertEqual(content.selectedPresetID, work.id)
        scheduled.first?.fire()
        XCTAssertEqual(renderer.last, .prompt(content), "旧告知到期不收起提示")
    }
}
