import AppKit
import XCTest
@testable import MenubarKit

// 票 19：未就绪链路协调器的就绪菜单接线扩展（票 18 语义延续 + 全量菜单注入）。
// 接缝：NotReadyGateCoordinator 的 makeReadyMenu 注入——就绪时菜单由注入闭包构建（票 19 全量菜单），
//       未就绪保持票 18 占位骨架（+ §8.4 重确认块）；refreshMenuNow 供权限外事件（恢复/撤销/
//       屏幕变化）触发菜单重建。
final class ReadyMenuInjectionTests: XCTestCase {
    private final class StatusSpy: StatusPresenting {
        private(set) var warningDotVisible = false
        private(set) var menus: [NSMenu] = []
        func setShowsWarningDot(_ visible: Bool) { warningDotVisible = visible }
        func set(menu: NSMenu) { menus.append(menu) }
        var lastMenu: NSMenu? { menus.last }
    }

    private let accessibilityGranted = Unboxed(true)
    private let screenCaptureGranted = Unboxed(true)
    private let titles = Unboxed<[String?]>(["邮件"])

    private var statusSpy: StatusSpy!

    override func setUp() {
        statusSpy = StatusSpy()
        accessibilityGranted.value = true
        screenCaptureGranted.value = true
        titles.value = ["邮件"]
    }

    private func makeCoordinator(makeReadyMenu: @escaping () -> NSMenu = { PlaceholderMenu.build() }) -> NotReadyGateCoordinator {
        let monitor = PermissionMonitor(
            accessibilityProbe: { [accessibilityGranted] in accessibilityGranted.value },
            screenCaptureProbe: { [screenCaptureGranted] in screenCaptureGranted.value },
            titleSampler: { [titles] in titles.value })
        return NotReadyGateCoordinator(
            monitor: monitor,
            statusItem: statusSpy,
            makeReadyMenu: makeReadyMenu)
    }

    private var lastMenuTitles: [String] {
        statusSpy.lastMenu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
    }

    /// 就绪状态：菜单由注入的 makeReadyMenu 构建（票 19 全量菜单替换占位骨架）
    func testReadyStatusBuildsMenuViaInjectedClosure() {
        let marker = NSMenu(title: "wired")
        let coordinator = makeCoordinator { marker }
        coordinator.start()
        XCTAssertFalse(statusSpy.warningDotVisible)
        XCTAssertTrue(statusSpy.lastMenu === marker, "就绪时必须用注入闭包的全量菜单")
    }

    /// 未就绪状态：保持票 18 占位骨架（默认 makeReadyMenu 不参与）
    func testNotReadyKeepsPlaceholderSkeleton() {
        accessibilityGranted.value = false
        screenCaptureGranted.value = false
        let coordinator = makeCoordinator()
        coordinator.start()

        XCTAssertTrue(statusSpy.warningDotVisible)
        XCTAssertTrue(lastMenuTitles.contains("状态行（占位）"), "未就绪保持票 18 占位骨架")
        XCTAssertFalse(lastMenuTitles.contains("立即恢复") && lastMenuTitles.contains("退出 Winductor")
                       && !lastMenuTitles.contains("状态行（占位）"))
    }

    /// refreshMenuNow：权限状态未变时也可强制重建（恢复/撤销/屏幕变化后的刷新入口）
    func testRefreshMenuNowRebuildsWithoutPermissionChange() {
        var buildCount = 0
        let coordinator = makeCoordinator {
            buildCount += 1
            return NSMenu(title: "wired-\(buildCount)")
        }
        coordinator.start()  // start 内首检基线 + apply 各建一次（票 18 既有路径），至少建一次
        let buildCountAtStart = buildCount
        XCTAssertGreaterThanOrEqual(buildCountAtStart, 1)

        coordinator.refreshMenuNow()
        XCTAssertEqual(buildCount, buildCountAtStart + 1, "refreshMenuNow 必须再次调用注入闭包重建菜单")
        XCTAssertEqual(statusSpy.menus.count, buildCount)
    }

    /// 运行中重确认降级：未就绪 + §8.4 引导块照旧（票 18 语义不回归）
    func testReconfirmBlockStillInstalledWhenNotReady() {
        let coordinator = makeCoordinator()
        coordinator.start()  // 基线：标题可读（就绪）
        titles.value = [nil]  // 运行中标题全空 → §8.4 重确认信号
        _ = coordinator.monitor.checkNow()

        XCTAssertFalse(coordinator.monitor.status.isReady)
        XCTAssertTrue(statusSpy.warningDotVisible)
        XCTAssertTrue(lastMenuTitles.contains(ScreenCaptureReconfirmGuide.statusLineTitle))
    }
}
