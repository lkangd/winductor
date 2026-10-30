import AppKit
import Core
import SnapshotEngine
import RestoreEngine
import XCTest
@testable import MenubarKit
@testable import Core  // 构造 Displays.Info（memberwise init 为 internal，Seams.swift 冻结不可改）
@testable import RestoreEngine  // 构造 RestoreReport（memberwise init 为 internal）

// 票 19：菜单接线协调器（spec §8.2 动作接线 + §8.5 通知 + §8.1 图标三态）。
// 接缝：MenuRestoreCoordinator 对注入接缝的输出——
//   SnapshotRestoring fake（断言恢复调用与图标装饰顺序）、UndoPerforming fake（撤销调用与 §8.6 通知）、
//   SystemNotifying fake（通知投递）、LoginItemServicing fake（登录启动切换）、StatusIconControlling fake、
//   文件夹打开/菜单刷新闭包。TriggerChain 用真机（fake 调度器驱动）验证通知桥接与观察者入口。
final class MenuRestoreCoordinatorTests: XCTestCase {
    // MARK: 假件

    private final class FakeRestorer: SnapshotRestoring, @unchecked Sendable {
        private(set) var restoreCalls = 0
        var report: RestoreReport
        init(report: RestoreReport = RestoreReport(okCount: 12, skipCount: 1, failCount: 0,
                                                   matchedCount: 13, untouchedLiveCount: 2,
                                                   undoSnapshotURL: nil)) {
            self.report = report
        }
        func restore(snapshot: Snapshot) throws -> RestoreReport {
            restoreCalls += 1
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

    // MARK: 装配

    private var displays: [Displays.Info] = []
    private var capabilityLayers: [CapabilityLayerStatus] = [
        CapabilityLayerStatus(layerNumber: 2, displayName: "Space 归属", available: true),
        CapabilityLayerStatus(layerNumber: 3, displayName: "全屏状态", available: true),
        CapabilityLayerStatus(layerNumber: 4, displayName: "最小化窗口归位", available: true),
    ]
    private var openedFolders: [URL] = []
    private var refreshCalls = 0
    private var store: SnapshotStore!
    private var restorer: FakeRestorer!
    private var undo: FakeUndo!
    private var notifier: FakeNotifier!
    private var icon: FakeIcon!
    private var login: FakeLogin!
    private var scheduler: FakeScheduler!

    override func setUp() {
        displays = Self.makeDisplays(["d-1", "d-2", "d-3"])
        capabilityLayers = [
            CapabilityLayerStatus(layerNumber: 2, displayName: "Space 归属", available: true),
            CapabilityLayerStatus(layerNumber: 3, displayName: "全屏状态", available: true),
            CapabilityLayerStatus(layerNumber: 4, displayName: "最小化窗口归位", available: true),
        ]
        openedFolders = []
        refreshCalls = 0
        store = SnapshotStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("wlr-menu-coordinator-\(UUID().uuidString)"))
        restorer = FakeRestorer()
        undo = FakeUndo()
        notifier = FakeNotifier()
        icon = FakeIcon()
        login = FakeLogin()
        scheduler = FakeScheduler()
    }

    private static func makeDisplays(_ uuids: [String]) -> [Displays.Info] {
        uuids.enumerated().map { index, uuid in
            Displays.Info(id: CGDirectDisplayID(index + 1),
                          bounds: CGRect(x: index * 2000, y: 0, width: 2000, height: 1200),
                          uuid: uuid)
        }
    }

    /// 现势快照落盘（与 displays 的 UUID 集合一致 → matchSnapshot 精确命中）
    private func writeLiveSnapshot() throws {
        let topology = displays.map {
            TopologyDisplay(uuid: $0.uuid ?? "", localizedName: "屏",
                            frame: SnapshotDisplayFrame(x: $0.bounds.minX, y: 0, w: 2000, h: 1200),
                            orientation: 0)
        }
        let spaces = topology.map { SnapshotSpace(displayUUID: $0.uuid, index: 1, kind: .user, fullscreenAppBundleID: nil) }
        let snapshot = Snapshot(capturedAt: Date(), topology: topology, spaces: spaces, windows: [])
        try store.write(snapshot, topologyKey: SnapshotStore.topologyKey(forDisplayUUIDs: displays.compactMap(\.uuid)))
    }

    private func makeCoordinator() -> MenuRestoreCoordinator {
        MenuRestoreCoordinator(
            store: store,
            restorer: restorer,
            spaces: FakeSpaceList(["s1"]),
            displaysProvider: { [weak self] in self?.displays ?? [] },
            scheduler: scheduler,
            undo: undo,
            icon: icon,
            notifier: notifier,
            loginItem: login,
            capabilityLayers: { [weak self] in self?.capabilityLayers ?? [] },
            snapshotsFolder: URL(fileURLWithPath: "/tmp/wlr-snapshots"),
            logsFolder: URL(fileURLWithPath: "/tmp/wlr-logs"),
            openFolder: { [weak self] in self?.openedFolders.append($0) },
            refreshMenu: { [weak self] in self?.refreshCalls += 1 })
    }

    /// 经全量菜单项 target/action 触发动作（与真实点击同路径）
    private func perform(_ coordinator: MenuRestoreCoordinator, title: String) throws {
        let menu = coordinator.makeReadyMenu()
        guard let item = menu.items.first(where: { $0.title == title }) else {
            XCTFail("菜单缺项：\(title)")
            return
        }
        item.target?.perform(item.action!, with: item)
    }

    // MARK: 立即恢复（§8.2 → chain.restoreNow → 完成通知 §8.5 + 图标三态 §8.1）

    /// 立即恢复：经触发链 restoreNow 调恢复引擎一次；完成通知计数照 §8.5；结束图标回到常态
    func testRestoreNowCallsRestorerDeliversNoticeAndResetsIcon() throws {
        try writeLiveSnapshot()
        let coordinator = makeCoordinator()

        try perform(coordinator, title: "立即恢复")

        XCTAssertEqual(restorer.restoreCalls, 1, "立即恢复必须经触发链调引擎（命令级一致）")
        XCTAssertEqual(notifier.deliveries.count, 1)
        XCTAssertEqual(notifier.deliveries.first?.title, "恢复完成")
        XCTAssertEqual(notifier.deliveries.first?.body, "恢复完成：12 窗口归位、1 跳过、0 失败")
        XCTAssertEqual(icon.sequence, ["restoring", "normal"], "恢复中临时同步图形，结束即回（§8.1）")
    }

    /// 降级附注：恢复后 [degrade] 收集层名拼进通知（§8.5「本次 Space 归属层失效（几何已恢复）」）
    func testRestoreNoticeIncludesDegradeAppendix() throws {
        try writeLiveSnapshot()
        let collector = DegradeCollectingLog(inner: nil)
        collector.write("[degrade] layer=L2 reason=no-op detail=x")
        let coordinator = MenuRestoreCoordinator(
            store: store,
            restorer: restorer,
            spaces: FakeSpaceList(["s1"]),
            displaysProvider: { [weak self] in self?.displays ?? [] },
            scheduler: scheduler,
            degradeCollector: collector,
            undo: undo, icon: icon, notifier: notifier, loginItem: login,
            capabilityLayers: { [weak self] in self?.capabilityLayers ?? [] },
            snapshotsFolder: URL(fileURLWithPath: "/tmp/wlr-snapshots"),
            logsFolder: URL(fileURLWithPath: "/tmp/wlr-logs"),
            openFolder: { [weak self] in self?.openedFolders.append($0) },
            refreshMenu: { [weak self] in self?.refreshCalls += 1 })

        try perform(coordinator, title: "立即恢复")

        XCTAssertEqual(notifier.deliveries.first?.body,
                       "恢复完成：12 窗口归位、1 跳过、0 失败；本次 Space 归属层失效（几何已恢复）")
    }

    /// 自动触发链路（观察者入口 → 防抖 → 稳定两轮 → 恢复 → 通知）：桥接与命令级一致
    func testScreenParametersChangeDrivesAutoRestoreAndNotice() throws {
        try writeLiveSnapshot()
        let coordinator = makeCoordinator()
        // 模拟插回：集合变大（链基线在 start 时建立；此处直接改 displays 后发事件）
        displays = Self.makeDisplays(["d-1", "d-2", "d-3", "d-4"])
        try writeLiveSnapshot()  // 新拓扑的现势快照
        coordinator.screenParametersDidChange()

        scheduler.fireAll()  // 防抖 1.5s 到点
        scheduler.fireAll()  // 稳定判据第 1 轮到点
        scheduler.fireAll()  // 稳定判据第 2 轮到点 → 触发恢复

        XCTAssertEqual(restorer.restoreCalls, 1, "集合变大且精确匹配快照 → 自动恢复一次")
        XCTAssertEqual(notifier.deliveries.first?.title, "恢复完成")
        XCTAssertEqual(refreshCalls >= 1, true, "屏幕变化必须刷新菜单（状态行三态）")
    }

    // MARK: 撤销上次恢复（§8.6 两段式通知 + 计数通知）

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
        let coordinator = makeCoordinator()

        let menu = coordinator.makeReadyMenu()
        let item = menu.items.first { $0.title == "撤销上次恢复" }
        XCTAssertEqual(item?.isEnabled, false)
        XCTAssertNil(item?.action)
        XCTAssertEqual(undo.undoCalls, 0)
    }

    // MARK: 登录时启动（唯一设置项）与 Finder 入口

    func testLoginLaunchToggleCallsServiceAndRefreshes() throws {
        let coordinator = makeCoordinator()

        try perform(coordinator, title: "登录时启动")
        XCTAssertEqual(login.enableCalls, 1)
        XCTAssertEqual(login.isEnabled, true, "勾选切换后菜单勾选态取自服务现状")

        try perform(coordinator, title: "登录时启动")
        XCTAssertEqual(login.disableCalls, 1)
        XCTAssertEqual(refreshCalls, 2)
    }

    /// 登录勾选态取自服务（SMAppService 注入接缝）
    func testLoginCheckboxReflectsServiceState() throws {
        login.enabled = true
        let coordinator = makeCoordinator()
        let menu = coordinator.makeReadyMenu()
        XCTAssertEqual(menu.items.first { $0.title == "登录时启动" }?.state, .on)
    }

    func testFinderEntriesOpenConfiguredFolders() throws {
        let coordinator = makeCoordinator()

        try perform(coordinator, title: "打开快照文件夹")
        try perform(coordinator, title: "打开日志文件夹")

        XCTAssertEqual(openedFolders, [
            URL(fileURLWithPath: "/tmp/wlr-snapshots"),
            URL(fileURLWithPath: "/tmp/wlr-logs"),
        ])
    }

    // MARK: 通知桥接与菜单刷新

    /// 部分拓扑提示通知经桥接投递（§6.2 A5）
    func testPartialTopologyNoticeBridgesToNotifier() {
        let coordinator = makeCoordinator()
        coordinator.handle(notice: .partialTopology(PartialTopologyNotice(currentDisplayCount: 2)))

        XCTAssertEqual(notifier.deliveries.count, 1)
        XCTAssertEqual(notifier.deliveries.first?.title, "未能自动恢复")
    }

    /// 菜单打开时原位刷新：状态行/撤销可用性按构建时刻现状重算
    func testMenuWillOpenRefreshesItemsInPlace() throws {
        try writeLiveSnapshot()
        undo.canUndoValue = true
        let coordinator = makeCoordinator()
        let menu = coordinator.makeReadyMenu()
        XCTAssertNotNil(menu.items.first { $0.title == "三屏 · 快照就绪" })

        displays = Self.makeDisplays(["e-1", "e-2", "e-3"])  // 拓扑变化且无该拓扑快照
        undo.canUndoValue = false
        coordinator.refreshItemsInPlace(menu)

        XCTAssertNotNil(menu.items.first { $0.title == "三屏 · 无匹配快照" })
        XCTAssertEqual(menu.items.first { $0.title == "撤销上次恢复" }?.isEnabled, false)
    }

    /// 状态行三态随拓扑/快照匹配态切换（spec §8.2）：快照就绪 → 无匹配快照 → 一屏（拔出）
    func testStatusLineFollowsTopologyAndSnapshotMatch() throws {
        try writeLiveSnapshot()
        let coordinator = makeCoordinator()

        let menu1 = coordinator.makeReadyMenu()
        XCTAssertNotNil(menu1.items.first { $0.title == "三屏 · 快照就绪" })

        displays = Self.makeDisplays(["f-1", "f-2", "f-3"])  // 多屏但无该拓扑现势快照
        let menu2 = coordinator.makeReadyMenu()
        XCTAssertNotNil(menu2.items.first { $0.title == "三屏 · 无匹配快照" })

        displays = Self.makeDisplays(["d-1"])  // 单屏 = 拔出态（与快照无关）
        let menu3 = coordinator.makeReadyMenu()
        XCTAssertNotNil(menu3.items.first { $0.title == "一屏（拔出）" })
    }

    /// 能力状态行随 probeLayers 结果呈现降级措辞（fake 探针）
    func testCapabilityLineFollowsProbeResult() throws {
        capabilityLayers = [
            CapabilityLayerStatus(layerNumber: 2, displayName: "Space 归属", available: false),
            CapabilityLayerStatus(layerNumber: 3, displayName: "全屏状态", available: true),
            CapabilityLayerStatus(layerNumber: 4, displayName: "最小化窗口归位", available: true),
        ]
        let coordinator = makeCoordinator()
        let menu = coordinator.makeReadyMenu()
        XCTAssertNotNil(menu.items.first { $0.title == "能力状态：以下恢复层不可用：Space 归属（详见日志）" })

        capabilityLayers[0] = CapabilityLayerStatus(layerNumber: 2, displayName: "Space 归属", available: true)
        let refreshed = coordinator.makeReadyMenu()
        XCTAssertNotNil(refreshed.items.first { $0.title == "能力状态：全部可用" })
    }
}
