import AppKit
import Core
import Foundation
import SnapshotEngine
import XCTest
@testable import MenubarKit

// ui-refactor 票 03：统一主窗口的编排（MainWindowModel）与窗口宿主生命周期（MainWindowController）。
// 接缝：MainWindowModel 公共接口（reload / select / selectCurrentTopology / updatePermissionStatus / 通用页动作）
// 与其 state、general；MainWindowController（show / showCurrentTopology / reloadIfVisible / 屏幕参数变化刷新）。
// 存储用真实 PresetStore（临时目录）；当前拓扑经注入闭包（调用计数 = 重读次数）；通用页动作经菜单同源 WiredMenuContent 假件。
final class MainWindowModelTests: XCTestCase {
    private final class NoDialogs: PresetManagerDialogs, PresetOverwriteConfirming {
        func promptRename(currentName: String, message: String?) -> String? { nil }
        func promptAlias(currentAlias: String?, placeholder: String) -> String? { nil }
        func confirmDelete(presetName: String) -> Bool { false }
        func showError(_ message: String) {}
        func confirmOverwrite(presetName: String) -> Bool { false }
    }

    private var directory: URL!
    private var store: PresetStore!
    private var clock: Date!
    private var current: ObservedTopology!
    private var topologyReads = 0
    private var canUndo = false
    private var loginChecked = false
    private var actions: [String] = []
    private var controllers: [MainWindowController] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("winductor-mainwindow-\(UUID().uuidString)", isDirectory: true)
        clock = Date(timeIntervalSince1970: 1_794_148_200)
        store = PresetStore(directory: directory, now: { [unowned self] in clock })
        current = office
        topologyReads = 0
        canUndo = false
        loginChecked = false
        actions = []
    }

    override func tearDownWithError() throws {
        controllers.forEach { $0.window?.close() }
        controllers = []
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 选中

    /// 打开即落在当前拓扑（无预设也是）；点通用/关于切页；点其他拓扑同步拓扑页内容的选中拓扑
    func testSelectionDefaultsToCurrentTopologyAndFollowsClicks() throws {
        try save("家", on: home)
        let model = makeModel()

        XCTAssertEqual(model.state.selection, .topology(office.identity.key), "当前拓扑尚无预设也选中它")
        XCTAssertEqual(model.state.sections.map(\.kind), [.current, .others, .app])

        model.select(.about)
        XCTAssertEqual(model.state.selection, .about)

        model.select(.topology(home.identity.key))
        XCTAssertEqual(model.state.selection, .topology(home.identity.key))
        XCTAssertEqual(model.presets.state.selectedKey, home.identity.key, "拓扑页内容跟随侧栏")
    }

    /// 菜单「管理预设…」入口：不论之前停在哪页 / 哪个拓扑，回到当前拓扑
    func testSelectCurrentTopologyResetsSelection() throws {
        try save("家", on: home)
        let model = makeModel()
        model.select(.topology(home.identity.key))

        model.selectCurrentTopology()
        XCTAssertEqual(model.state.selection, .topology(office.identity.key))
        XCTAssertEqual(model.presets.state.selectedKey, office.identity.key)

        model.select(.general)
        model.selectCurrentTopology()
        XCTAssertEqual(model.state.selection, .topology(office.identity.key))
    }

    /// 拓扑变化（reload 重读）后侧栏分组跟随：新当前拓扑进「当前排列」
    func testReloadFollowsTopologyChange() throws {
        try save("工作", on: office)
        let model = makeModel()
        current = home

        model.reload()

        XCTAssertEqual(model.state.sections.first?.rows.map(\.page), [.topology(home.identity.key)])
        XCTAssertEqual(model.state.sections[1].rows.map(\.page), [.topology(office.identity.key)])
        XCTAssertEqual(model.state.selection, .topology(home.identity.key))
    }

    // MARK: 通用页

    /// 权限现状推送 → 通用页状态点与侧栏状态点
    func testPermissionStatusDrivesDots() {
        let model = makeModel(status: status(ready: true))
        XCTAssertTrue(model.general.screenCaptureGranted)
        XCTAssertFalse(model.state.sections.flatMap(\.rows).contains(where: \.showsStatusDot))

        model.updatePermissionStatus(status(ready: false))

        XCTAssertFalse(model.general.screenCaptureGranted)
        XCTAssertEqual(model.state.sections.flatMap(\.rows).filter(\.showsStatusDot).map(\.page), [.general])
    }

    /// 通用页动作与菜单同源（WiredMenuContent 闭包）；勾选态 / 撤销可用性在 reload 时取菜单现状
    func testGeneralActionsRouteToMenuContent() {
        let model = makeModel()
        XCTAssertFalse(model.general.canUndo)

        model.undoLastRestore()
        XCTAssertEqual(actions, [], "不可撤销时不调用")

        canUndo = true
        loginChecked = true
        model.reload()
        XCTAssertTrue(model.general.canUndo)
        XCTAssertTrue(model.general.loginLaunchChecked)

        model.undoLastRestore()
        model.toggleLoginLaunch()
        model.openPresetsFolder()
        model.openLogsFolder()
        model.openPermissionGuide()
        XCTAssertEqual(actions, ["undo", "login", "presets", "logs", "guide"])
    }

    // MARK: 窗口宿主

    /// 单实例：再次打开复用同一窗口；关闭即隐藏（不释放），再开仍是它
    func testWindowIsSingleInstanceAndCloseHides() throws {
        let controller = makeController()

        controller.show()
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.isVisible)
        controller.show()
        XCTAssertTrue(controller.window === window)

        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isReleasedWhenClosed)

        controller.show()
        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(window.isVisible)
    }

    /// Swish 式外观：全尺寸内容、透明隐藏标题栏、可缩放、最小约 720×520
    func testWindowChrome() throws {
        let controller = makeController()
        controller.show()
        let window = try XCTUnwrap(controller.window)

        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 720)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.height, 520)
    }

    /// 打开即重读；外部事件后 reloadIfVisible 仅在可见时重读
    func testReloadIfVisibleOnlyWhileVisible() throws {
        let controller = makeController()
        controller.reloadIfVisible()
        let beforeShow = topologyReads

        controller.reloadIfVisible()
        XCTAssertEqual(topologyReads, beforeShow, "未打开：不重读")

        controller.show()
        XCTAssertEqual(topologyReads, beforeShow + 1, "打开即重读（一次）")
        try save("新", on: office)
        controller.reloadIfVisible()
        XCTAssertEqual(controller.model.presets.state.selected?.rows.map(\.name), ["新"])

        controller.window?.performClose(nil)
        let afterClose = topologyReads
        controller.reloadIfVisible()
        XCTAssertEqual(topologyReads, afterClose, "已关闭（隐藏）：不重读")
    }

    /// 打开只重读一次：呈现时窗口随即成为 key（生产 makeKeyAndOrderFront 同步发 windowDidBecomeKey）不再重读；
    /// 此后再激活（切走再回来）照常重读（spec §5.1 打开/激活时刷新）
    func testOpeningReloadsOnceEvenWhenWindowBecomesKey() throws {
        let controller = makeController(becomesKeyOnPresent: true)
        let before = topologyReads

        controller.show()
        XCTAssertEqual(topologyReads, before + 1, "打开只重读一次")

        let window = try XCTUnwrap(controller.window)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        XCTAssertEqual(topologyReads, before + 2, "再激活重读")

        controller.show()  // 关窗前再打开（呈现再次成为 key）
        XCTAssertEqual(topologyReads, before + 3, "再打开仍只重读一次")
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        XCTAssertEqual(topologyReads, before + 4, "其后的激活不被吞")
    }

    /// 屏幕参数变化：可见时立即重读一次，settleDelay 后再补一次
    func testScreenParametersChangeReloadsNowAndAfterSettle() throws {
        let controller = makeController(settleDelay: 0.05)
        controller.show()
        let before = topologyReads

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(topologyReads, before + 1, "立即重读")

        let settled = expectation(description: "settle reload")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(topologyReads, before + 2, "稳定后补刷一次")
    }

    // MARK: 红绿灯（ui-refactor 票 10）

    /// 真窗口的红绿灯：垂直中心与 header 标题中心对齐（距窗顶 25），关闭按钮左缘 = 侧栏菜单行高亮底左缘；
    /// 缩放、AppKit 布局复位（系统把按钮放回默认位）、失焦/激活、关闭后重新打开都保持
    func testTrafficLightsAlignWithHeaderTitleAndSidebarRows() throws {
        XCTAssertEqual(MainWindowMetrics.headerHeight, 50)
        XCTAssertEqual(MainWindowMetrics.sidebarRowInset, 10, "侧栏行左右内缩 10（行高亮底左缘）")
        let controller = makeController()
        controller.show()
        let window = try XCTUnwrap(controller.window)
        assertTrafficLights(in: window, "打开")

        window.setContentSize(NSSize(width: 1000, height: 720))
        assertTrafficLights(in: window, "放大")
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 740, height: 560)), display: true)
        assertTrafficLights(in: window, "缩小")

        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        close.setFrameOrigin(NSPoint(x: 9, y: 9))  // 模拟 AppKit 布局把按钮放回系统默认位
        assertTrafficLights(in: window, "布局复位后")

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        assertTrafficLights(in: window, "失焦再激活")

        window.performClose(nil)
        controller.show()
        assertTrafficLights(in: window, "关闭后重新打开")
    }

    private func assertTrafficLights(in window: NSWindow, _ when: String, file: StaticString = #filePath,
                                     line: UInt = #line) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        XCTAssertEqual(buttons.count, 3, file: file, line: line)
        let rects = buttons.map { $0.convert($0.bounds, to: nil) }  // 窗口坐标（原点在窗口左下）
        for rect in rects {
            XCTAssertEqual(window.frame.height - rect.midY, 25, accuracy: 0.5, "\(when)：中心距窗顶", file: file, line: line)
        }
        XCTAssertEqual(rects[0].minX, MainWindowMetrics.sidebarRowInset, accuracy: 0.5, "\(when)：关闭按钮左缘",
                       file: file, line: line)
        XCTAssertLessThan(rects[0].maxX, rects[1].minX, "\(when)：按钮不重叠", file: file, line: line)
        XCTAssertLessThan(rects[1].maxX, rects[2].minX, "\(when)：按钮不重叠", file: file, line: line)
        // 按钮整个落在标题栏容器内（否则超出部分点不中）
        for (button, rect) in zip(buttons, rects) {
            guard let container = button.superview?.superview else { return XCTFail("无标题栏容器", file: file, line: line) }
            XCTAssertTrue(container.convert(container.bounds, to: nil).contains(rect), "\(when)：按钮在标题栏容器内",
                          file: file, line: line)
        }
    }

    // MARK: 辅助

    private func status(ready: Bool) -> PermissionMonitor.Status {
        PermissionMonitor.Status(accessibilityGranted: true, screenCaptureGranted: ready,
                                 screenCaptureNeedsReconfirm: false)
    }

    private func menuContent() -> WiredMenuContent {
        WiredMenuContent(statusLineTitle: "", canSavePreset: true, restorePresets: [], canUndo: canUndo,
                         loginLaunchChecked: loginChecked, capabilityTitle: "",
                         onSavePreset: {}, onRestorePreset: { _ in },
                         onUndo: { [unowned self] in actions.append("undo") },
                         onManagePresets: nil,
                         onToggleLoginLaunch: { [unowned self] in actions.append("login") },
                         onOpenPresetsFolder: { [unowned self] in actions.append("presets") },
                         onOpenLogsFolder: { [unowned self] in actions.append("logs") })
    }

    private func makeModel(status: PermissionMonitor.Status? = nil) -> MainWindowModel {
        let dialogs = NoDialogs()
        let overwrite = OverwritePresetFlow(
            store: store,
            capture: { [unowned self] in LayoutCapture(snapshot: snapshot(), topology: current) },
            availability: { .available },
            confirm: dialogs,
            captureExecutor: { $0() },
            mainExecutor: { $0() })
        let presets = PresetManagerModel(store: store,
                                         topologyProvider: { [unowned self] in topologyReads += 1; return current },
                                         overwrite: overwrite,
                                         restore: { _, _ in },
                                         dialogs: dialogs)
        return MainWindowModel(presets: presets,
                               permissionStatus: status ?? self.status(ready: true),
                               menuContent: { [unowned self] in menuContent() },
                               openPermissionGuide: { [unowned self] in actions.append("guide") },
                               presetsFolder: directory,
                               logsFolder: directory.appendingPathComponent("logs"),
                               version: "9.9.9")
    }

    /// - Parameter becomesKeyOnPresent: 模拟生产呈现（makeKeyAndOrderFront）在呈现中同步发 windowDidBecomeKey
    private func makeController(settleDelay: TimeInterval = 2, becomesKeyOnPresent: Bool = false) -> MainWindowController {
        // 离屏呈现：不激活本进程、窗口挪到屏幕外（测试期不闪窗）
        let controller = MainWindowController(model: makeModel(), settleDelay: settleDelay) { window in
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.orderFront(nil)
            if becomesKeyOnPresent {
                (window.delegate as? MainWindowController)?
                    .windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
            }
        }
        controllers.append(controller)
        return controller
    }

    @discardableResult
    private func save(_ name: String, on topology: ObservedTopology) throws -> Preset {
        defer { clock = clock.addingTimeInterval(60) }
        return try store.addPreset(name: name, snapshot: snapshot(), topology: topology)
    }

    private func snapshot() -> Snapshot {
        Snapshot(capturedAt: clock, topology: [], spaces: [], windows: [])
    }

    private func topology(_ screens: [(String, String, CGFloat)]) -> ObservedTopology {
        ObservedTopology(screens: screens.map { uuid, name, x in
            TopologyScreen(uuid: uuid, name: name, frame: CGRect(x: x, y: 0, width: 1512, height: 982),
                           pixelWidth: 3024, pixelHeight: 1964, rotation: 0, isMirrored: false)
        })
    }

    private var home: ObservedTopology { topology([("BUILTIN", "内置", 0), ("DELL-1", "DELL U2723QE", 1512)]) }
    private var office: ObservedTopology { topology([("BUILTIN", "内置", 0), ("LG-1", "LG HDR 4K", 1512)]) }
}
