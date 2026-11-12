import AppKit
import XCTest
@testable import MenubarKit

// 票 18：未就绪链路协调器测试（spec §4.6/§8.3/§8.4 的呈现决策）。
// 接缝：NotReadyGateCoordinator 对 StatusPresenting / GuideWindowPresenting 两个呈现接缝的输出：
//   - 未就绪 → 状态项未就绪徽记（ui-refactor §4.2）
//   - 首启未就绪 → 弹引导窗一次；启动时就绪 → 不弹（重启后不再弹）
//   - 运行中重确认降级 → 菜单内引导块（§8.4 逐字），不弹窗
final class NotReadyGateCoordinatorTests: XCTestCase {
    // MARK: 假件

    private final class StatusSpy: StatusPresenting {
        private(set) var notReadyBadgeVisible = false
        private(set) var menus: [NSMenu] = []
        func setShowsNotReadyBadge(_ visible: Bool) { notReadyBadgeVisible = visible }
        func set(menu: NSMenu) { menus.append(menu) }
        var lastMenu: NSMenu? { menus.last }
    }

    private final class GuideSpy: GuideWindowPresenting {
        private(set) var showCount = 0
        private(set) var updates: [PermissionMonitor.Status] = []
        /// 每次推进带的「本次运行中出现过未就绪」（决定齐备态是否要重启）
        private(set) var hasBeenNotReadyFlags: [Bool] = []
        func show() { showCount += 1 }
        func update(status: PermissionMonitor.Status, hasBeenNotReady: Bool) {
            updates.append(status)
            hasBeenNotReadyFlags.append(hasBeenNotReady)
        }
    }

    // MARK: 状态

    private let accessibilityGranted = Unboxed(false)
    private let screenCaptureGranted = Unboxed(false)
    private let titles = Unboxed([String?]() )
    private var statusSpy: StatusSpy!
    private var guideSpy: GuideSpy!
    private var coordinator: NotReadyGateCoordinator!

    override func setUp() {
        statusSpy = StatusSpy()
        guideSpy = GuideSpy()
        let monitor = PermissionMonitor(
            accessibilityProbe: { [accessibilityGranted] in accessibilityGranted.value },
            screenCaptureProbe: { [screenCaptureGranted] in screenCaptureGranted.value },
            titleSampler: { [titles] in titles.value }
        )
        coordinator = NotReadyGateCoordinator(monitor: monitor,
                                              statusItem: statusSpy,
                                              makeGuideWindow: { [guideSpy] in guideSpy })
    }

    private func checkNow() { _ = coordinator.monitor.checkNow() }

    private var lastMenuTitles: [String] {
        statusSpy.lastMenu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
    }

    func testSettingsSurvivesNotReadyRefreshAndRuntimePermissionTransitions() throws {
        accessibilityGranted.value = true
        screenCaptureGranted.value = true
        titles.value = ["邮件"]
        var opened = 0
        var readyBuilds = 0
        var restored: [String] = []
        coordinator = NotReadyGateCoordinator(monitor: coordinator.monitor, statusItem: statusSpy,
            makeGuideWindow: { [guideSpy] in guideSpy! },
            makeReadyMenu: {
                readyBuilds += 1
                let menu = WiredMenuBuilder.build(WiredMenuContent(
                    statusLineTitle: "就绪", canSavePreset: true,
                    restorePresets: [.init(id: "work", name: "工作", isAuto: true)], canUndo: false,
                    capabilityTitle: "能力", onSavePreset: {},
                    onRestorePreset: { restored.append($0) }, onUndo: {}, onManagePresets: nil,
                    onOpenSettings: { opened += 1 }))
                menu.addItem(withTitle: "ready-menu", action: nil, keyEquivalent: "")
                return menu
            }, onOpenSettings: { opened += 1 })
        coordinator.start()
        XCTAssertTrue(lastMenuTitles.contains("ready-menu"))
        titles.value = [nil]
        checkNow()
        coordinator.refreshMenuNow()
        XCTAssertFalse(lastMenuTitles.contains("ready-menu"))
        XCTAssertTrue(lastMenuTitles.contains("屏幕录制权限需重新确认"))
        let readyBefore = readyBuilds
        let menu = try XCTUnwrap(statusSpy.lastMenu)
        let settings = try XCTUnwrap(menu.item(withTitle: "设置"))
        XCTAssertTrue(settings.isEnabled)
        _ = settings.target?.perform(try XCTUnwrap(settings.action), with: settings)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(readyBuilds, readyBefore, "设置不构建就绪菜单、不绕过门控")
        XCTAssertEqual(menu.item(withTitle: "恢复预设")?.isEnabled, false)
        XCTAssertTrue(menu.item(withTitle: "保存预设")!.submenu!.items.allSatisfy { !$0.isEnabled })
        titles.value = ["邮件"]
        checkNow()
        XCTAssertTrue(lastMenuTitles.contains("ready-menu"))
        XCTAssertFalse(lastMenuTitles.contains("屏幕录制权限需重新确认"))
        XCTAssertFalse(statusSpy.notReadyBadgeVisible)
        let restoredMenu = try XCTUnwrap(statusSpy.lastMenu?.item(withTitle: "恢复预设")?.submenu)
        let work = try XCTUnwrap(restoredMenu.item(withTitle: "工作（自动）"))
        _ = work.target?.perform(try XCTUnwrap(work.action), with: work)
        XCTAssertEqual(restored, ["work"], "权限恢复后重新接好恢复菜单回调")
    }

    // MARK: 首启决策（§8.3：启动时 notReady→先弹引导窗；ready→直接常态运行，重启后不再弹）

    /// 启动未就绪：未就绪徽记 + 弹引导窗一次 + 引导窗跟随状态
    func testStartNotReadyShowsGuideAndNotReadyBadge() throws {
        var settingsOpened = 0
        coordinator = NotReadyGateCoordinator(monitor: coordinator.monitor, statusItem: statusSpy,
            makeGuideWindow: { [guideSpy] in guideSpy! }, onOpenSettings: { settingsOpened += 1 })
        accessibilityGranted.value = false
        screenCaptureGranted.value = false
        titles.value = []
        coordinator.start()

        XCTAssertTrue(statusSpy.notReadyBadgeVisible)
        XCTAssertEqual(guideSpy.showCount, 1, "首启未就绪必须弹一次引导窗")
        XCTAssertEqual(guideSpy.updates.last?.isReady, false)
        let settings = try XCTUnwrap(statusSpy.lastMenu?.item(withTitle: "设置"))
        XCTAssertTrue(settings.isEnabled)
        _ = settings.target?.perform(try XCTUnwrap(settings.action), with: settings)
        XCTAssertEqual(settingsOpened, 1)
        XCTAssertEqual(statusSpy.lastMenu?.item(withTitle: "恢复预设")?.isEnabled, false)
    }

    /// 启动已就绪：不弹窗、无未就绪徽记（重启后授权生效的常态路径）
    func testStartReadyRunsQuietly() {
        accessibilityGranted.value = true
        screenCaptureGranted.value = true
        titles.value = ["邮件"]
        coordinator.start()

        XCTAssertFalse(statusSpy.notReadyBadgeVisible)
        XCTAssertEqual(guideSpy.showCount, 0, "启动时就绪不得弹引导窗（重启后不再弹）")
    }

    /// 主窗口「授权引导…」（ui-refactor 票 03）：就绪后也能按需打开，带上现状；再次打开复用同一窗口
    func testShowPermissionGuideOnDemand() {
        accessibilityGranted.value = true
        screenCaptureGranted.value = true
        titles.value = ["邮件"]
        coordinator.start()
        var made = 0
        let factoryCoordinator = NotReadyGateCoordinator(monitor: coordinator.monitor, statusItem: statusSpy,
                                                         makeGuideWindow: { [guideSpy] in made += 1; return guideSpy! })

        factoryCoordinator.showPermissionGuide()
        factoryCoordinator.showPermissionGuide()

        XCTAssertEqual(made, 1, "单实例")
        XCTAssertEqual(guideSpy.showCount, 2)
        XCTAssertEqual(guideSpy.updates.last?.isReady, true)
    }

    /// 启动即就绪后按需打开：本次运行从未未就绪 → 窗内齐备态无需重启
    func testShowPermissionGuideWhenLaunchedReadyNeedsNoRestart() {
        accessibilityGranted.value = true
        screenCaptureGranted.value = true
        titles.value = ["邮件"]
        coordinator.start()

        coordinator.showPermissionGuide()

        XCTAssertEqual(guideSpy.updates.last?.isReady, true)
        XCTAssertEqual(guideSpy.hasBeenNotReadyFlags.last, false)
    }

    /// 运行中降级又恢复后按需打开：出现过未就绪 → 齐备态仍提示重启（§8.4 引导语「然后重启应用」）
    func testShowPermissionGuideAfterRuntimeLapseRequiresRestart() {
        accessibilityGranted.value = true
        screenCaptureGranted.value = true
        titles.value = ["邮件"]
        coordinator.start()
        titles.value = [nil]
        checkNow()
        titles.value = ["邮件"]
        checkNow()

        coordinator.showPermissionGuide()

        XCTAssertEqual(guideSpy.updates.last?.isReady, true)
        XCTAssertEqual(guideSpy.hasBeenNotReadyFlags.last, true)
    }

    /// 齐备推进：引导窗未关闭，收到就绪状态（窗内换「✓ …【立即重启】」文案）
    func testGuideWindowFollowsReadiness() {
        coordinator.start()
        accessibilityGranted.value = true
        screenCaptureGranted.value = true
        titles.value = ["邮件"]
        checkNow()

        XCTAssertEqual(guideSpy.showCount, 1, "不重复弹窗")
        XCTAssertEqual(guideSpy.updates.last?.isReady, true)
        XCTAssertEqual(guideSpy.hasBeenNotReadyFlags.last, true, "首启未就绪后齐备：需重启")
        XCTAssertFalse(statusSpy.notReadyBadgeVisible)
    }

    // MARK: 运行中重确认降级（§8.4：菜单内引导、不弹窗）

    /// 就绪运行中标题全空 → 未就绪徽记 + 菜单顶部 §8.4 逐字引导块 + 不弹窗
    func testRuntimeLapseInstallsMenuBlockWithoutPopup() {
        accessibilityGranted.value = true
        screenCaptureGranted.value = true
        titles.value = ["邮件"]
        coordinator.start()

        titles.value = [nil]
        checkNow()

        XCTAssertTrue(statusSpy.notReadyBadgeVisible)
        XCTAssertEqual(guideSpy.showCount, 0, "重确认降级走菜单引导，不弹窗（§8.4）")
        XCTAssertEqual(lastMenuTitles.prefix(2), [
            "屏幕录制权限需重新确认",
            "macOS 会定期要求重新确认屏幕录制权限。请在系统设置中重新打开开关，然后重启应用。",
        ])
        // 状态行可点，说明行置灰
        XCTAssertEqual(statusSpy.lastMenu?.items.first?.isEnabled, true)
        XCTAssertEqual(statusSpy.lastMenu?.items[1].isEnabled, false)
    }

    /// 标题恢复可读 → 菜单回到占位骨架（「状态行（占位）」回归）、未就绪徽记撤下
    func testLapseRecoveryRestoresPlaceholderMenu() {
        accessibilityGranted.value = true
        screenCaptureGranted.value = true
        titles.value = ["邮件"]
        coordinator.start()
        titles.value = [nil]
        checkNow()

        titles.value = ["邮件"]
        checkNow()

        XCTAssertFalse(statusSpy.notReadyBadgeVisible)
        XCTAssertEqual(lastMenuTitles.first, "状态行（占位）")
        XCTAssertFalse(lastMenuTitles.contains("屏幕录制权限需重新确认"))
    }
}
