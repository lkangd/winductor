import AppKit
import Core
import SnapshotEngine
import RestoreEngine
import XCTest
@testable import MenubarKit
@testable import Core  // 构造 Displays.Info（memberwise init 为 internal，Seams.swift 冻结不可改）
@testable import RestoreEngine  // 构造 RestoreReport（memberwise init 为 internal）

// 票 19 → display-presets 票 06：菜单接线协调器（display-presets spec §6.1 菜单 + 状态行四态；§8.5 通知 + §8.1 图标三态沿用）。
// 接缝：MenuRestoreCoordinator 的全量菜单（makeReadyMenu，经菜单项 target/action 点击）对注入接缝的输出——
//   SnapshotRestoring fake（断言恢复调用、所恢复的快照与图标装饰顺序）、UndoPerforming fake（撤销调用与 §8.6 通知）、
//   SystemNotifying fake（通知投递）、LoginItemServicing fake、StatusIconControlling fake、文件夹打开/菜单刷新闭包。
//   PresetStore 用真实存储（临时目录）；TriggerChain 用真机（fake 调度器驱动）；保存流程用真实 SavePresetFlow
//   （拍快照与输入框经注入假件，两段执行器同步执行）。
final class MenuRestoreCoordinatorTests: XCTestCase {
    // MARK: 假件

    private final class FakeRestorer: SnapshotRestoring, @unchecked Sendable {
        private(set) var restoreCalls = 0
        private(set) var restoredSnapshots: [Snapshot] = []
        var report: RestoreReport
        init(report: RestoreReport = RestoreReport(okCount: 12, skipCount: 1, failCount: 0,
                                                   matchedCount: 13, untouchedLiveCount: 2,
                                                   undoSnapshotURL: nil)) {
            self.report = report
        }
        func restore(snapshot: Snapshot) throws -> RestoreReport {
            restoreCalls += 1
            restoredSnapshots.append(snapshot)
            return report
        }
    }

    private final class FakeUndo: UndoPerforming {
        var canUndoValue = false
        var outcome: Result<UndoReport, Error> = .success(UndoReport(
            okCount: 5, skipCount: 0, failCount: 0, matchedCount: 5,
            untouchedLiveCount: 0,
            undoSnapshotURL: URL(fileURLWithPath: "/tmp/undo.json"),
            fullscreenPendingCount: 0))
        private(set) var undoCalls = 0
        func canUndo() -> Bool { canUndoValue }
        func undo() throws -> UndoReport {
            undoCalls += 1
            return try outcome.get()
        }
    }

    private final class FakeNotifier: SystemNotifying {
        private(set) var deliveries: [(title: String, body: String)] = []
        func deliver(title: String, body: String) { deliveries.append((title, body)) }
    }

    private final class FakeIcon: StatusIconControlling {
        private(set) var sequence: [String] = []
        func showNormalIcon() { sequence.append("normal") }
        func showRestoringIcon() { sequence.append("restoring") }
    }

    private final class FakeLogin: LoginItemServicing {
        var enabled = false
        private(set) var enableCalls = 0
        private(set) var disableCalls = 0
        var isEnabled: Bool { enabled }
        func enable() throws { enableCalls += 1; enabled = true }
        func disable() throws { disableCalls += 1; enabled = false }
    }

    private final class TickingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_794_000_000)
        func tick() -> Date {
            lock.lock(); defer { lock.unlock() }
            current += 60
            return current
        }
    }

    /// 输入框假件：按脚本依次应答（nil = 取消）
    private final class ScriptedPrompt: PresetNamePrompting {
        var answers: [String?]
        private(set) var askedCount = 0
        init(_ answers: [String?]) { self.answers = answers }
        func promptPresetName(defaultName: String, message: String?) -> String? {
            askedCount += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    /// 覆盖确认框假件：按脚本应答（用尽 = 取消）
    private final class ScriptedConfirm: PresetOverwriteConfirming {
        var answers: [Bool]
        init(_ answers: [Bool]) { self.answers = answers }
        func confirmOverwrite(presetName: String) -> Bool { answers.isEmpty ? false : answers.removeFirst() }
    }

    private final class FakeSpaceList: SpaceListProviding, @unchecked Sendable {
        let signature: [String]
        init(_ signature: [String]) { self.signature = signature }
        func spaceList() -> [String]? { signature }
    }

    private final class FakeScheduler: TriggerChainScheduling, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [(TimeInterval, @Sendable () -> Void)] = []
        func schedule(after: TimeInterval, _ fire: @escaping @Sendable () -> Void) {
            lock.lock(); pending.append((after, fire)); lock.unlock()
        }
        func cancelScheduled() { lock.lock(); pending.removeAll(); lock.unlock() }
        /// 逐点触发挂起回调（防抖/稳定轮次）
        func fireAll() {
            lock.lock(); let current = pending; pending.removeAll(); lock.unlock()
            current.forEach { $1() }
        }
    }

    private final class FakePopover: RestorePopoverRendering {
        var onEvent: ((RestorePopoverEvent) -> Void)?
        private(set) var rendered: [RestorePopoverPresentation] = []
        func render(_ presentation: RestorePopoverPresentation) { rendered.append(presentation) }
    }

    // MARK: 装配

    private var displays: [Displays.Info] = []
    private var mirrored = false
    private var capabilityLayers: [CapabilityLayerStatus] = []
    private var openedFolders: [URL] = []
    private var refreshCalls = 0
    private var presetStore: PresetStore!
    private var restorer: FakeRestorer!
    private var undo: FakeUndo!
    private var enqueueUsed = false
    private var notifier: FakeNotifier!
    private var icon: FakeIcon!
    private var login: FakeLogin!
    private var scheduler: FakeScheduler!
    private var popover: FakePopover!
    private var prompt: ScriptedPrompt!
    private var restoring = false

    override func setUp() {
        displays = Self.makeDisplays(["d-1", "d-2", "d-3"])
        mirrored = false
        capabilityLayers = [
            CapabilityLayerStatus(layerNumber: 2, displayName: "Space 归属", available: true),
            CapabilityLayerStatus(layerNumber: 3, displayName: "全屏状态", available: true),
            CapabilityLayerStatus(layerNumber: 4, displayName: "最小化窗口归位", available: true),
        ]
        openedFolders = []
        refreshCalls = 0
        // 每次写入时钟前进 1 分钟：预设按保存时间排序可预期（同秒才按名称）
        let clock = TickingClock()
        presetStore = PresetStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("winductor-menutests-\(UUID().uuidString)"), now: { clock.tick() })
        restorer = FakeRestorer()
        undo = FakeUndo()
        notifier = FakeNotifier()
        icon = FakeIcon()
        login = FakeLogin()
        scheduler = FakeScheduler()
        popover = FakePopover()
        prompt = ScriptedPrompt([])
        restoring = false
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: presetStore.directory)
    }

    private static func makeDisplays(_ uuids: [String]) -> [Displays.Info] {
        uuids.enumerated().map { index, uuid in
            Displays.Info(id: CGDirectDisplayID(index + 1),
                          bounds: CGRect(x: index * 2000, y: 0, width: 2000, height: 1200),
                          uuid: uuid)
        }
    }

    /// 当前 displays 的拓扑观测（屏并排贴合；mirrored = 首屏处于镜像集合；不读真实 CG）
    private var observedTopology: ObservedTopology {
        ObservedTopology(screens: displays.enumerated().map { index, info in
            TopologyScreen(uuid: info.uuid ?? "", name: "屏", frame: info.bounds, pixelWidth: 2000, pixelHeight: 1200,
                           rotation: 0, isMirrored: mirrored && index == 0)
        })
    }

    /// 当前布局的快照（marker 写进首屏 Space 的全屏应用字段，用来区分不同预设的快照）
    private func currentSnapshot(marker: String = "") -> Snapshot {
        let topology = displays.map {
            TopologyDisplay(uuid: $0.uuid ?? "", localizedName: "屏",
                            frame: SnapshotDisplayFrame(x: $0.bounds.minX, y: 0, w: 2000, h: 1200),
                            orientation: 0)
        }
        let spaces = topology.map {
            SnapshotSpace(displayUUID: $0.uuid, index: 1, kind: .user, fullscreenAppBundleID: marker.isEmpty ? nil : marker)
        }
        return Snapshot(capturedAt: Date(timeIntervalSince1970: 1_794_000_000), topology: topology, spaces: spaces, windows: [])
    }

    /// 当前拓扑存一个预设（拓扑首个预设默认自动）
    @discardableResult
    private func addPreset(_ name: String) throws -> Preset {
        try presetStore.addPreset(name: name, snapshot: currentSnapshot(marker: name), topology: observedTopology)
    }

    private var currentKey: String { observedTopology.identity.key }

    private func makeCoordinator(degradeCollector: DegradeCollectingLog? = nil,
                                 openPresetManager: (() -> Void)? = nil,
                                 openSettings: (() -> Void)? = nil,
                                 readiness: @escaping () -> Bool = { true },
                                 enqueue: ((@escaping @Sendable () -> Void) -> Void)? = nil,
                                 overwriteConfirm: [Bool] = []) -> MenuRestoreCoordinator {
        let savePreset = SavePresetFlow(
            store: presetStore,
            capture: { [unowned self] in LayoutCapture(snapshot: currentSnapshot(), topology: observedTopology) },
            prompt: prompt,
            isReady: readiness,
            isMirrored: { [unowned self] in mirrored },
            isRestoring: { [unowned self] in restoring },
            captureExecutor: { $0() },
            mainExecutor: { $0() })
        let overwrite = OverwritePresetFlow(
            store: presetStore,
            capture: { [unowned self] in LayoutCapture(snapshot: currentSnapshot(), topology: observedTopology) },
            availability: { savePreset.availability() },
            confirm: ScriptedConfirm(overwriteConfirm),
            captureExecutor: { $0() },
            mainExecutor: { $0() })
        return MenuRestoreCoordinator(
            presetStore: presetStore,
            restorer: restorer,
            spaces: FakeSpaceList(["d-1#1#0", "d-2#1#0", "d-3#1#0", "d-4#1#0"]),
            topologyProvider: { [weak self] in self?.observedTopology ?? ObservedTopology(screens: []) },
            readiness: readiness,
            scheduler: scheduler,
            restoreEnqueue: enqueue ?? { [weak self] work in self?.enqueueUsed = true; work() },
            degradeCollector: degradeCollector,
            undo: undo,
            icon: icon,
            notifier: notifier,
            loginItem: login,
            capabilityLayers: { [weak self] in self?.capabilityLayers ?? [] },
            savePreset: savePreset,
            openPresetManager: openPresetManager,
            openSettings: openSettings,
            overwritePreset: overwrite,
            presetsFolder: URL(fileURLWithPath: "/tmp/winductor-presets"),
            logsFolder: URL(fileURLWithPath: "/tmp/winductor-logs"),
            openFolder: { [weak self] in self?.openedFolders.append($0) },
            refreshMenu: { [weak self] in self?.refreshCalls += 1 },
            popover: popover)
    }

    private func titles(_ menu: NSMenu) -> [String] { menu.items.filter { !$0.isSeparatorItem }.map(\.title) }

    private func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
        for entry in menu.items {
            if entry.title == title { return entry }
            if let submenu = entry.submenu, let match = item(submenu, title) { return match }
        }
        return nil
    }

    /// 经全量菜单项 target/action 触发动作（与真实点击同路径）
    private func perform(_ coordinator: MenuRestoreCoordinator, title: String) throws {
        let menuItem = try XCTUnwrap(item(coordinator.makeReadyMenu(), title), "菜单缺项：\(title)")
        _ = menuItem.target?.perform(try XCTUnwrap(menuItem.action, "项不可点：\(title)"), with: menuItem)
    }

    /// 「恢复预设 ▸」子菜单项（按显示标题取）
    private func restoreItem(_ menu: NSMenu, _ title: String) throws -> NSMenuItem {
        let submenu = try XCTUnwrap(item(menu, "恢复预设")?.submenu, "恢复预设无子菜单")
        return try XCTUnwrap(submenu.items.first { $0.title == title }, "子菜单缺项：\(title)")
    }

    private func click(_ menuItem: NSMenuItem) throws {
        _ = menuItem.target?.perform(try XCTUnwrap(menuItem.action), with: menuItem)
    }

    // MARK: 状态行四态（spec §6.1，随拓扑 / 预设 / 镜像切换）

    func testStatusLineFollowsTopologyPresetsAndMirroring() throws {
        let coordinator = makeCoordinator()
        XCTAssertEqual(titles(coordinator.makeReadyMenu()).first, "3 屏 · 无预设")

        try addPreset("工作")  // 拓扑首个预设默认自动
        try addPreset("家")
        XCTAssertEqual(titles(coordinator.makeReadyMenu()).first, "3 屏 · 2 个预设（自动：工作）")

        try presetStore.setAuto(false, presetID: try XCTUnwrap(presetStore.topology(key: currentKey)?.autoPreset?.id),
                                topologyKey: currentKey)
        XCTAssertEqual(titles(coordinator.makeReadyMenu()).first, "3 屏 · 2 个预设")

        displays = Self.makeDisplays(["d-1", "d-2"])  // 拔一块屏 = 另一拓扑（无预设）
        XCTAssertEqual(titles(coordinator.makeReadyMenu()).first, "2 屏 · 无预设")

        mirrored = true
        XCTAssertEqual(titles(coordinator.makeReadyMenu()).first, "镜像中")
    }

    /// 菜单打开时原位刷新：状态行/撤销可用性按打开时刻现状重算
    func testMenuWillOpenRefreshesItemsInPlace() throws {
        try addPreset("工作")
        undo.canUndoValue = true
        let coordinator = makeCoordinator()
        let menu = coordinator.makeReadyMenu()
        XCTAssertEqual(titles(menu).first, "3 屏 · 1 个预设（自动：工作）")

        displays = Self.makeDisplays(["e-1", "e-2", "e-3"])  // 拓扑变化且新拓扑无预设
        undo.canUndoValue = false
        coordinator.refreshItemsInPlace(menu)

        XCTAssertEqual(titles(menu).first, "3 屏 · 无预设")
        XCTAssertEqual(item(menu, "撤销上次恢复")?.isEnabled, false)
        XCTAssertEqual(item(menu, "恢复预设")?.isEnabled, false)
    }

    // MARK: 恢复预设 ▸（与自动恢复同一管线：触发链 → 恢复引擎 → 记录最近恢复 → 完成通知）

    /// 子菜单列出当前拓扑预设（保存时间升序），自动预设带标记；无预设 / 镜像中置灰
    func testRestoreSubmenuListsCurrentTopologyPresets() throws {
        let coordinator = makeCoordinator()
        XCTAssertEqual(item(coordinator.makeReadyMenu(), "恢复预设")?.isEnabled, false, "无预设置灰")

        try addPreset("工作")
        try addPreset("家")
        let submenu = try XCTUnwrap(item(coordinator.makeReadyMenu(), "恢复预设")?.submenu)
        // 恢复子菜单仅含当前排列预设，不再混入覆盖动作
        XCTAssertEqual(submenu.items.map(\.title), ["工作（自动）", "家"])

        mirrored = true
        XCTAssertEqual(item(coordinator.makeReadyMenu(), "恢复预设")?.isEnabled, false, "镜像中禁用恢复（spec §3.3）")
    }

    /// 点击子菜单项：经触发链离主线程恢复该预设快照一次，记录最近恢复，完成通知计数照 §8.5，图标恢复中→常态
    func testRestoreSubmenuItemRestoresThroughChainAndRecordsLastRestored() throws {
        try addPreset("工作")
        let home = try addPreset("家")
        let coordinator = makeCoordinator()

        try click(try restoreItem(coordinator.makeReadyMenu(), "家"))

        XCTAssertEqual(restorer.restoredSnapshots, [home.snapshot], "恢复所点预设的快照")
        XCTAssertTrue(enqueueUsed, "恢复管线经注入执行器（离主线程）")
        XCTAssertEqual(presetStore.topology(key: currentKey)?.lastRestoredPresetID, home.id, "成功后记录最近恢复（spec §4.4）")
        XCTAssertEqual(notifier.deliveries.map(\.title), ["恢复完成"])
        XCTAssertEqual(notifier.deliveries.first?.body, "恢复完成：12 窗口归位、1 跳过、0 失败")
        XCTAssertEqual(icon.sequence, ["restoring", "normal"], "恢复中图标，结束即回（ui-refactor §4.2）")
        XCTAssertGreaterThanOrEqual(refreshCalls, 1, "恢复后刷新菜单")
    }

    /// 菜单打开后拓扑已变：点旧拓扑的预设不恢复（仅当前拓扑，spec §5.2）
    func testRestoreSubmenuItemIgnoredAfterTopologyChanged() throws {
        try addPreset("工作")
        let coordinator = makeCoordinator()
        let stale = try restoreItem(coordinator.makeReadyMenu(), "工作（自动）")

        displays = Self.makeDisplays(["d-1", "d-2"])
        try click(stale)

        XCTAssertEqual(restorer.restoreCalls, 0)
        XCTAssertNil(presetStore.topology(key: currentKey))
        XCTAssertEqual(notifier.deliveries.map(\.title), ["未恢复预设"], "被拒不静默：告知用户")
        XCTAssertEqual(notifier.deliveries.first?.body, "屏幕排列已变化，只能恢复当前屏幕排列下的预设")
    }

    /// 恢复提示「恢复」被拒（提示弹出后拓扑已变）：与菜单同口径告知，不恢复
    func testPromptRestoreRejectedNotifiesUser() throws {
        let coordinator = makeCoordinator()
        try addPreset("工作")
        coordinator.handle(outcome: .promptNeeded(try XCTUnwrap(presetStore.topology(key: currentKey))))

        displays = Self.makeDisplays(["d-1", "d-2"])
        popover.onEvent?(.restoreTapped)

        XCTAssertEqual(restorer.restoreCalls, 0)
        XCTAssertEqual(notifier.deliveries.map(\.title), ["未恢复预设"])
    }

    /// 「保存预设 ▸」→「覆盖预设 ▸」（spec §4.3，display-presets 票 07）：确认后把当前布局写进所点预设，名称与自动保留，刷新菜单
    func testOverwriteSubmenuItemOverwritesPresetWithCurrentLayout() throws {
        try addPreset("工作")
        let home = try addPreset("家")
        let coordinator = makeCoordinator(overwriteConfirm: [true])
        let targets = try XCTUnwrap(try XCTUnwrap(item(coordinator.makeReadyMenu(), "覆盖预设")).submenu)

        try click(try XCTUnwrap(targets.items.first { $0.title == "家" }))

        let stored = presetStore.topology(key: currentKey)?.presets.first { $0.id == home.id }
        XCTAssertEqual(stored?.snapshot, currentSnapshot())
        XCTAssertNotEqual(stored?.snapshot, home.snapshot)
        XCTAssertEqual(stored?.name, "家")
        XCTAssertEqual(stored?.isAuto, false)
        XCTAssertGreaterThanOrEqual(refreshCalls, 1, "覆盖后刷新菜单")
        XCTAssertEqual(restorer.restoreCalls, 0, "覆盖不触发恢复")
    }

    /// 恢复进行中：「覆盖预设」置灰（与保存同口径）
    func testOverwriteSubmenuDisabledWhileRestoring() throws {
        try addPreset("工作")
        let coordinator = makeCoordinator()
        restoring = true

        XCTAssertEqual(try XCTUnwrap(item(coordinator.makeReadyMenu(), "覆盖预设")).isEnabled, false)
    }

    /// 降级附注：恢复后 [degrade] 收集层名拼进通知（§8.5「本次 Space 归属层失效（几何已恢复）」）
    func testRestoreNoticeIncludesDegradeAppendix() throws {
        try addPreset("工作")
        let collector = DegradeCollectingLog(inner: nil)
        collector.write("[degrade] layer=L2 reason=no-op detail=x")
        let coordinator = makeCoordinator(degradeCollector: collector)

        try click(try restoreItem(coordinator.makeReadyMenu(), "工作（自动）"))

        XCTAssertEqual(notifier.deliveries.first?.body,
                       "恢复完成：12 窗口归位、1 跳过、0 失败；本次 Space 归属层失效（几何已恢复）")
    }

    /// 自动触发链路（观察者入口 → 防抖 → 稳定两轮 → 自动预设恢复 → 告知）：同一管线
    func testScreenParametersChangeDrivesAutoRestoreAndNotice() throws {
        let coordinator = makeCoordinator()
        displays = Self.makeDisplays(["d-1", "d-2", "d-3", "d-4"])  // 插屏：新拓扑带自动预设
        try addPreset("工作")
        coordinator.screenParametersDidChange()

        scheduler.fireAll()  // 防抖 1.5s 到点
        scheduler.fireAll()  // 稳定判据第 1 轮到点
        scheduler.fireAll()  // 稳定判据第 2 轮到点 → 触发恢复

        XCTAssertEqual(restorer.restoreCalls, 1, "新拓扑有自动预设 → 自动恢复一次")
        XCTAssertTrue(notifier.deliveries.isEmpty, "自动恢复告知改走 popover，不再发系统通知（§6.3）")
        guard case .notice(let notice, _)? = popover.rendered.last else { return XCTFail("应弹自动恢复告知") }
        XCTAssertEqual(notice.headline, "已按『工作』恢复")
        XCTAssertEqual(notice.detail, "12 窗口归位、1 跳过、0 失败")
        XCTAssertEqual(refreshCalls >= 1, true, "屏幕变化必须刷新菜单（状态行四态）")

        // 告知「撤销」走菜单同款撤销管线（离主线程 + 撤销完成通知）
        undo.canUndoValue = true
        popover.onEvent?(.undoTapped)
        XCTAssertEqual(undo.undoCalls, 1)
        XCTAssertEqual(enqueueUsed, true)
        XCTAssertEqual(notifier.deliveries.first?.title, "撤销完成")
    }

    // MARK: 保存新预设（display-presets 票 03 SavePresetFlow）

    /// 点击：拍快照 → 输入框 → 存入当前拓扑；保存后刷新菜单，状态行与「恢复预设 ▸」随之更新
    func testSavePresetItemRunsFlowAndRefreshesMenu() throws {
        prompt.answers = ["工作"]
        let coordinator = makeCoordinator()

        try perform(coordinator, title: "保存新预设")

        XCTAssertEqual(prompt.askedCount, 1)
        XCTAssertEqual(presetStore.topology(key: currentKey)?.presets.map(\.name), ["工作"])
        XCTAssertEqual(refreshCalls, 1, "保存后刷新菜单")
        let menu = coordinator.makeReadyMenu()
        XCTAssertEqual(titles(menu).first, "3 屏 · 1 个预设（自动：工作）")
        XCTAssertNoThrow(try restoreItem(menu, "工作（自动）"))
    }

    /// 取消输入框：不写、不刷新
    func testSavePresetCancelledWritesNothing() throws {
        prompt.answers = [nil]
        let coordinator = makeCoordinator()

        try perform(coordinator, title: "保存新预设")

        XCTAssertNil(presetStore.topology(key: currentKey))
        XCTAssertEqual(refreshCalls, 0)
    }

    /// 镜像中 / 恢复进行中：保存项置灰（spec §4.3）
    func testSavePresetItemDisabledWhileMirroredOrRestoring() {
        let coordinator = makeCoordinator()
        XCTAssertEqual(item(coordinator.makeReadyMenu(), "保存新预设")?.isEnabled, true)

        mirrored = true
        XCTAssertEqual(item(coordinator.makeReadyMenu(), "保存新预设")?.isEnabled, false)

        mirrored = false
        restoring = true
        XCTAssertEqual(item(coordinator.makeReadyMenu(), "保存新预设")?.isEnabled, false)
    }

    // MARK: 管理预设…（打开主窗口，此处只验入口接缝）

    func testManagePresetsRoutesToInjectedOpener() throws {
        XCTAssertEqual(item(makeCoordinator().makeReadyMenu(), "管理预设…")?.isEnabled, false, "未装配窗口：置灰")

        var opened = 0
        let coordinator = makeCoordinator(openPresetManager: { opened += 1 })
        try perform(coordinator, title: "管理预设…")
        XCTAssertEqual(opened, 1)
    }

    func testSettingsRoutesToInjectedOpener() throws {
        XCTAssertEqual(item(makeCoordinator().makeReadyMenu(), "设置")?.isEnabled, false)
        var opened = 0
        let coordinator = makeCoordinator(openSettings: { opened += 1 })
        try perform(coordinator, title: "设置")
        XCTAssertEqual(opened, 1)
    }

    func testOtherTopologyPresetsNeverEnableOrPopulateOverwriteAndRestore() throws {
        try addPreset("其他排列预设")
        let coordinator = makeCoordinator()
        displays = Self.makeDisplays(["new-display"])
        let menu = coordinator.makeReadyMenu()
        XCTAssertEqual(item(menu, "覆盖预设")?.isEnabled, false)
        XCTAssertNil(item(menu, "覆盖预设")?.submenu)
        XCTAssertEqual(item(menu, "恢复预设")?.isEnabled, false)
        XCTAssertNil(item(menu, "其他排列预设（自动）"))
        XCTAssertEqual(item(menu, "保存新预设")?.isEnabled, true)
    }

    func testStaleReadyMenuAndMainWindowActionsCannotSaveOrRestoreAfterPermissionLoss() throws {
        let work = try addPreset("工作")
        var ready = true
        let coordinator = makeCoordinator(readiness: { ready }, overwriteConfirm: [true])
        let menu = coordinator.makeReadyMenu()
        let restore = try restoreItem(menu, "工作（自动）")
        let save = try XCTUnwrap(item(menu, "保存新预设"))
        let overwrite = try XCTUnwrap(item(menu, "覆盖预设")?.submenu?.items.first)
        ready = false
        try click(save)
        try click(overwrite)
        try click(restore)
        coordinator.saveCurrentLayout()
        coordinator.restorePreset(id: work.id, topologyKey: currentKey)
        XCTAssertEqual(prompt.askedCount, 0)
        XCTAssertEqual(restorer.restoreCalls, 0)
        XCTAssertEqual(presetStore.topology(key: currentKey)?.presets, [work])
        XCTAssertFalse(coordinator.menuContent().canSavePreset)
        XCTAssertFalse(coordinator.menuContent().canOverwritePreset)
        XCTAssertEqual(notifier.deliveries.last?.body, "权限未齐备，不能恢复预设")
        ready = true
        coordinator.restorePreset(id: work.id, topologyKey: currentKey)
        XCTAssertEqual(restorer.restoreCalls, 1)
    }

    // MARK: 撤销上次恢复（§8.6 两段式通知 + 计数通知）

    /// 撤销经注入执行器离开调用线程（undo 跑全管线 ≈ 分钟级，不能阻塞主线程）
    func testUndoRunsViaRestoreEnqueue() throws {
        undo.canUndoValue = true
        let coordinator = makeCoordinator()

        try perform(coordinator, title: "撤销上次恢复")

        XCTAssertEqual(enqueueUsed, true, "撤销管线必须经注入执行器（离主线程）")
        XCTAssertEqual(notifier.deliveries.count, 1, "完成通知照常投递")
    }

    func testUndoOldCallbackDoesNotEnqueueAfterPermissionLossAndRecovers() throws {
        undo.canUndoValue = true
        var ready = true
        let coordinator = makeCoordinator(readiness: { ready })
        let old = coordinator.menuContent()
        ready = false
        old.onUndo()
        XCTAssertFalse(enqueueUsed)
        XCTAssertEqual(undo.undoCalls, 0)
        XCTAssertFalse(coordinator.menuContent().canUndo)
        ready = true
        XCTAssertTrue(coordinator.menuContent().canUndo)
        old.onUndo()
        XCTAssertEqual(undo.undoCalls, 1)
    }

    func testQueuedUndoDoesNotRunIfPermissionsAreLostBeforeExecution() throws {
        undo.canUndoValue = true
        var ready = true
        var queued: [@Sendable () -> Void] = []
        let coordinator = makeCoordinator(readiness: { ready }, enqueue: { queued.append($0) })
        coordinator.menuContent().onUndo()
        XCTAssertEqual(queued.count, 1)
        ready = false
        queued.removeFirst()()
        XCTAssertEqual(undo.undoCalls, 0)
        XCTAssertTrue(notifier.deliveries.isEmpty)
        ready = true
        coordinator.menuContent().onUndo()
        queued.removeFirst()()
        XCTAssertEqual(undo.undoCalls, 1)
    }

    /// 两段式第一段：§8.6 逐字通知（N = fullscreenPendingCount）
    func testTwoStageUndoDeliversVerbatimNotice() throws {
        undo.canUndoValue = true
        undo.outcome = .success(UndoReport(
            okCount: 4, skipCount: 2, failCount: 0, matchedCount: 4, untouchedLiveCount: 0,
            undoSnapshotURL: URL(fileURLWithPath: "/tmp/undo.json"),
            fullscreenPendingCount: 2))
        let coordinator = makeCoordinator()

        try perform(coordinator, title: "撤销上次恢复")

        XCTAssertEqual(undo.undoCalls, 1)
        XCTAssertEqual(notifier.deliveries.count, 1)
        XCTAssertEqual(notifier.deliveries.first?.body,
                       "撤销完成。2 个全屏应用无法在后台退出全屏：请在对应屏幕按 Esc 退出全屏，然后再次点击「撤销上次恢复」完成剩余归位。")
    }

    /// 单层撤销：完成通知带计数（命令级 undo 输出的菜单栏形态）
    func testSingleStageUndoDeliversCountsNotice() throws {
        undo.canUndoValue = true
        let coordinator = makeCoordinator()

        try perform(coordinator, title: "撤销上次恢复")

        XCTAssertEqual(notifier.deliveries.first?.title, "撤销完成")
        XCTAssertEqual(notifier.deliveries.first?.body, "撤销完成：5 窗口归位、0 跳过、0 失败")
        XCTAssertEqual(refreshCalls >= 1, true, "撤销后必须刷新菜单（canUndo 态）")
    }

    /// canUndo == false：撤销菜单项置灰且不触发引擎（spec §7.4 入口禁用）
    func testUndoItemDisabledWhenCanUndoFalse() throws {
        undo.canUndoValue = false
        let menuItem = item(makeCoordinator().makeReadyMenu(), "撤销上次恢复")
        XCTAssertEqual(menuItem?.isEnabled, false)
        XCTAssertNil(menuItem?.action)
        XCTAssertEqual(undo.undoCalls, 0)
    }

    // MARK: 登录时启动（唯一设置项）与 Finder 入口

    func testLoginLaunchToggleCallsServiceAndRefreshes() throws {
        let coordinator = makeCoordinator()

        coordinator.menuContent().onToggleLoginLaunch()
        XCTAssertEqual(login.enableCalls, 1)
        XCTAssertEqual(login.isEnabled, true, "勾选切换后菜单勾选态取自服务现状")

        coordinator.menuContent().onToggleLoginLaunch()
        XCTAssertEqual(login.disableCalls, 1)
        XCTAssertEqual(refreshCalls, 2)
    }

    /// 登录勾选态取自服务（SMAppService 注入接缝）
    func testLoginCheckboxReflectsServiceState() throws {
        login.enabled = true
        XCTAssertTrue(makeCoordinator().menuContent().loginLaunchChecked)
    }

    func testFinderEntriesOpenConfiguredFolders() throws {
        let coordinator = makeCoordinator()

        coordinator.menuContent().onOpenPresetsFolder()
        coordinator.menuContent().onOpenLogsFolder()

        XCTAssertEqual(openedFolders, [
            URL(fileURLWithPath: "/tmp/winductor-presets"),
            URL(fileURLWithPath: "/tmp/winductor-logs"),
        ])
    }

    // MARK: 通知桥接与能力状态行

    /// 判定结果桥接（§6.2）：请求提示 → 恢复提示 popover；「恢复」走触发链手动恢复（完成通知照常）；收起提示 → 收起
    func testOutcomeBridgeShowsPromptRestoresAndDismisses() throws {
        let coordinator = makeCoordinator()
        try addPreset("工作")
        let topology = try XCTUnwrap(presetStore.topology(key: currentKey))

        coordinator.handle(outcome: .promptNeeded(topology))
        guard case .prompt(let content)? = popover.rendered.last else { return XCTFail("应弹恢复提示") }
        XCTAssertEqual(content.selected?.name, "工作")
        XCTAssertTrue(notifier.deliveries.isEmpty)

        popover.onEvent?(.restoreTapped)
        XCTAssertEqual(restorer.restoreCalls, 1)
        XCTAssertEqual(notifier.deliveries.first?.title, "恢复完成")

        coordinator.handle(outcome: .promptNeeded(topology))
        coordinator.handle(outcome: .dismissPrompt)
        XCTAssertEqual(popover.rendered.last, .hidden)
    }

    /// 能力状态行随 probeLayers 结果呈现降级措辞（fake 探针）
    func testCapabilityLineFollowsProbeResult() throws {
        capabilityLayers[0] = CapabilityLayerStatus(layerNumber: 2, displayName: "Space 归属", available: false)
        let coordinator = makeCoordinator()
        XCTAssertNotNil(item(coordinator.makeReadyMenu(), "能力状态：以下恢复层不可用：Space 归属（详见日志）"))

        capabilityLayers[0] = CapabilityLayerStatus(layerNumber: 2, displayName: "Space 归属", available: true)
        XCTAssertNotNil(item(coordinator.makeReadyMenu(), "能力状态：全部可用"))
    }
}
