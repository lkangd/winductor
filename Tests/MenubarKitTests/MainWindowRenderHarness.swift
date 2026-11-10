import AppKit
import Core
import SnapshotEngine
import SwiftUI
import XCTest
@testable import MenubarKit

// MainWindowRenderHarness — 统一主窗口的离屏渲染（人工与原型 PNG 对照用，ui-refactor 票 03）。
// 默认跳过；设环境变量 WINDUCTOR_MAINWINDOW_RENDER_DIR=<目录> 时把通用页、关于页 × 浅/深色 × key/失焦渲染为 PNG
// （文件名前缀取 WINDUCTOR_MAINWINDOW_RENDER_PREFIX，默认 ui-main-）；
// 拓扑页（ui-refactor 票 04）：当前拓扑展开详情 / 非当前拓扑 / 点屏筛选 × 浅/深色（另附当前拓扑失焦一张），
// 数据仿原型 MockData（前缀取 WINDUCTOR_TOPOLOGY_RENDER_PREFIX，默认 ui-topo-）。
// 固定 header（ui-refactor 票 10）：拓扑页 / 通用 / 关于 × 浅/深色，另附拓扑页上滚到 header 之下一张（看模糊），
// 文件名 ui-main-header-*.png。
// 离屏做法（票 10 改为真窗口形态，同授权窗 harness）：与真窗口同 styleMask / 配置（MainWindowController.install，含红绿灯定位）
// 的离屏标题栏窗口（不被约束回屏幕内），内容视图注入 controlActiveState；取图用窗口服务器合成结果（本进程自己的窗口，
// 不需录屏权限）——材质的背景模糊、真红绿灯与圆角都与真窗口一致（cacheDisplay 画不出背景模糊，仅作取不到时的回退）。
// 例：WINDUCTOR_MAINWINDOW_RENDER_DIR=/tmp swift test --filter MainWindowRenderHarness
final class MainWindowRenderHarness: XCTestCase {
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        /// 留在屏幕外（标题栏窗口默认会被约束回可见屏幕，测试期会闪到用户屏幕上）
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private final class NoDialogs: PresetManagerDialogs, PresetOverwriteConfirming {
        func promptRename(currentName: String, message: String?) -> String? { nil }
        func promptAlias(currentAlias: String?, placeholder: String) -> String? { nil }
        func confirmDelete(presetName: String) -> Bool { false }
        func showError(_ message: String) {}
        func confirmOverwrite(presetName: String) -> Bool { false }
    }

    private var directory: URL!

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testRenderMainWindowPages() throws {
        guard let dir = ProcessInfo.processInfo.environment["WINDUCTOR_MAINWINDOW_RENDER_DIR"] else {
            throw XCTSkip("未设 WINDUCTOR_MAINWINDOW_RENDER_DIR：跳过离屏渲染")
        }
        let prefix = ProcessInfo.processInfo.environment["WINDUCTOR_MAINWINDOW_RENDER_PREFIX"] ?? "ui-main-"
        let model = try makeModel()
        let output = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for (name, page) in [("general", MainWindowPage.general), ("about", .about)] {
            model.select(page)
            for dark in [false, true] {
                for inactive in [false, true] {
                    let file = "\(prefix)\(name)-\(dark ? "dark" : "light")-\(inactive ? "inactive" : "key").png"
                    try png(MainWindowView(model: model), dark: dark, inactive: inactive)
                        .write(to: output.appendingPathComponent(file))
                }
            }
        }
    }

    func testRenderTopologyPages() throws {
        guard let dir = ProcessInfo.processInfo.environment["WINDUCTOR_MAINWINDOW_RENDER_DIR"] else {
            throw XCTSkip("未设 WINDUCTOR_MAINWINDOW_RENDER_DIR：跳过离屏渲染")
        }
        let prefix = ProcessInfo.processInfo.environment["WINDUCTOR_TOPOLOGY_RENDER_PREFIX"] ?? "ui-topo-"
        let fixture = try makeTopologyFixture()
        let model = fixture.model
        let output = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func render(_ name: String, inactive: Bool = false, darkVariants: [Bool] = [false, true]) throws {
            for dark in darkVariants {
                let file = "\(prefix)\(name)-\(dark ? "dark" : "light")\(inactive ? "-inactive" : "").png"
                try png(MainWindowView(model: model), dark: dark, inactive: inactive)
                    .write(to: output.appendingPathComponent(file))
            }
        }

        // 当前拓扑全部收起（可见「演示」的 Space 不足提示）；再展开「工作」详情（原型 main-current.png 同态）
        model.selectCurrentTopology()
        let presetIDs = model.presets.state.selected?.rows.map(\.id) ?? []
        presetIDs.forEach { model.presets.toggleExpanded(presetID: $0) }
        try render("current-collapsed", darkVariants: [false])
        presetIDs.forEach { model.presets.toggleExpanded(presetID: $0) }  // 详情默认展开（票 10）
        try render("current")
        try render("current", inactive: true, darkVariants: [false])
        // 点屏筛选：只看 DELL #1
        model.presets.selectDisplay("DELL-1")
        try render("filter")
        // 非当前拓扑「家里」（详情默认展开）
        model.select(.topology(fixture.homeKey))
        try render("other")
    }

    /// 固定 header（票 10）：三页 × 浅/深色 + 拓扑页上滚到 header 之下（排列图从 header 下穿过）
    func testRenderHeaderPages() throws {
        guard let dir = ProcessInfo.processInfo.environment["WINDUCTOR_MAINWINDOW_RENDER_DIR"] else {
            throw XCTSkip("未设 WINDUCTOR_MAINWINDOW_RENDER_DIR：跳过离屏渲染")
        }
        let fixture = try makeTopologyFixture()
        let model = fixture.model
        let output = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let pages: [(String, MainWindowPage?, CGFloat)] = [("topology", nil, 0), ("general", .general, 0),
                                                           ("about", .about, 0), ("topology-scrolled", nil, 64)]
        for (name, page, scroll) in pages {
            if let page { model.select(page) } else { model.selectCurrentTopology() }
            for dark in [false, true] {
                try png(MainWindowView(model: model), dark: dark, inactive: false, scrollBy: scroll)
                    .write(to: output.appendingPathComponent("ui-main-header-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    // MARK: 数据：当前「内置 + DELL ×2」2 个预设 / 其他「家里」3 个 / 「内置视网膜显示器」1 个（原型同款）

    private func makeModel() throws -> MainWindowModel {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("winductor-mainrender-\(UUID().uuidString)", isDirectory: true)
        let clock = Unboxed(Date(timeIntervalSince1970: 1_794_148_200))
        let store = PresetStore(directory: directory, now: { clock.value })
        let office = topology([("BUILTIN", "内置视网膜显示器", 0), ("DELL-1", "DELL U2723QE", 1512),
                               ("DELL-2", "DELL U2723QE", 4072)])
        let home = topology([("BUILTIN", "内置视网膜显示器", 0), ("LG-1", "LG HDR 4K", 1512)])
        let laptop = topology([("BUILTIN", "内置视网膜显示器", 0)])
        for (name, topo) in [("旧", laptop), ("家", home), ("周末", home), ("游戏", home), ("工作", office), ("演示", office)] {
            try store.addPreset(name: name, snapshot: Snapshot(capturedAt: clock.value, topology: [], spaces: [], windows: []),
                                topology: topo)
            clock.value = clock.value.addingTimeInterval(60)
        }
        try store.setAlias("家里", topologyKey: home.identity.key)
        try store.setAlias("内置 + DELL U2723QE ×2", topologyKey: office.identity.key)

        let dialogs = NoDialogs()
        let overwrite = OverwritePresetFlow(
            store: store,
            capture: { LayoutCapture(snapshot: Snapshot(capturedAt: clock.value, topology: [], spaces: [], windows: []),
                                     topology: office) },
            availability: { .available }, confirm: dialogs,
            captureExecutor: { $0() }, mainExecutor: { $0() })
        let presets = PresetManagerModel(store: store, topologyProvider: { office }, overwrite: overwrite,
                                         restore: { _, _ in }, dialogs: dialogs)
        let content = WiredMenuContent(statusLineTitle: "", canSavePreset: true, restorePresets: [], canUndo: true,
                                       loginLaunchChecked: true, capabilityTitle: "",
                                       onSavePreset: {}, onRestorePreset: { _ in }, onUndo: {}, onManagePresets: nil,
                                       onToggleLoginLaunch: {}, onOpenPresetsFolder: {}, onOpenLogsFolder: {})
        // 通用页按「缺屏幕录制」渲染（与原型 main-general.png 同态：侧栏通用项带黄点）
        let notReady = PermissionMonitor.Status(accessibilityGranted: true, screenCaptureGranted: false,
                                                screenCaptureNeedsReconfirm: false)
        return MainWindowModel(presets: presets, permissionStatus: notReady, menuContent: { content },
                               openPermissionGuide: {},
                               presetsFolder: PresetStore.defaultDirectory,
                               logsFolder: SnapshotStore.defaultLogDirectory)
    }

    // MARK: 拓扑页数据：仿原型 MockData（办公室 DELL ×2 + 内置在下 / 家里 LG + 内置 / 单内置）

    private struct TopologyFixture {
        let model: MainWindowModel
        let workID: String
        let homeKey: String
    }

    private func makeTopologyFixture() throws -> TopologyFixture {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("winductor-toporender-\(UUID().uuidString)", isDirectory: true)
        let clock = Unboxed(Date(timeIntervalSince1970: 1_794_148_200))
        let store = PresetStore(directory: directory, now: { clock.value })
        let office = screens([("DELL-1", "DELL U2723QE", CGRect(x: 0, y: 0, width: 2560, height: 1440), false),
                              ("DELL-2", "DELL U2723QE", CGRect(x: 2560, y: 0, width: 2560, height: 1440), false),
                              ("BUILTIN", "内置视网膜显示器", CGRect(x: 1800, y: 1440, width: 1512, height: 982), true)])
        let home = screens([("LG-1", "LG UltraFine", CGRect(x: -400, y: 0, width: 2560, height: 1440), false),
                            ("BUILTIN", "内置视网膜显示器", CGRect(x: 2160, y: 458, width: 1512, height: 982), true)])
        let laptop = screens([("BUILTIN", "内置视网膜显示器", CGRect(x: 0, y: 0, width: 1512, height: 982), true)])

        let xcode = "com.apple.dt.Xcode", safari = "com.apple.Safari", slack = "com.tinyspeck.slackmacgap"
        let mail = "com.apple.mail", terminal = "com.apple.Terminal", notion = "notion.id"
        let keynote = "com.apple.iWork.Keynote", music = "com.apple.Music", messages = "com.apple.MobileSMS"
        let notes = "com.apple.Notes", finder = "com.apple.finder", pages = "com.apple.iWork.Pages"
        typealias Desk = (display: String, index: Int, fullscreen: String?, apps: [(String, Int, Int)])
        func add(_ name: String, on topology: ObservedTopology, _ desks: [Desk]) throws -> Preset {
            let snapshot = Snapshot(
                capturedAt: clock.value,
                topology: topology.displays.map {
                    TopologyDisplay(uuid: $0.uuid, localizedName: $0.name, frame: $0.frame, orientation: $0.rotation)
                },
                spaces: desks.map { SnapshotSpace(displayUUID: $0.display, index: $0.index,
                                                  kind: $0.fullscreen == nil ? .user : .fullscreen,
                                                  fullscreenAppBundleID: $0.fullscreen) },
                windows: desks.flatMap { desk in
                    desk.apps.flatMap { bundleID, count, minimized in
                        (0..<count).map { i in
                            SnapshotWindow(bundleID: bundleID, title: "w\(i)", siblingIndex: i, displayUUID: desk.display,
                                           spaceIndex: desk.index, x: 0, y: 0, w: 0.5, h: 0.5, minimized: i < minimized)
                        }
                    }
                })
            defer { clock.value = clock.value.addingTimeInterval(3600) }
            return try store.addPreset(name: name, snapshot: snapshot, topology: topology)
        }

        try add("出差", on: laptop, [("BUILTIN", 1, nil, [(safari, 1, 0)]), ("BUILTIN", 2, nil, [(slack, 1, 0)])])
        try add("写代码", on: home, [("LG-1", 1, nil, [(xcode, 1, 0), (terminal, 2, 0)]),
                                    ("BUILTIN", 1, nil, [(safari, 1, 0)])])
        try add("晚间", on: home, [("LG-1", 1, nil, [(safari, 2, 0), (music, 1, 0)]),
                                  ("BUILTIN", 1, nil, [(messages, 1, 0)])])
        let work = try add("工作", on: office, [
            ("DELL-1", 1, nil, [(xcode, 2, 0), (safari, 3, 1)]), ("DELL-1", 2, nil, [(slack, 1, 0), (mail, 1, 0)]),
            ("DELL-2", 1, nil, [(terminal, 4, 0), (notion, 1, 0)]), ("DELL-2", 2, keynote, []),
            ("BUILTIN", 1, nil, [(music, 1, 0), (messages, 1, 0)]),
        ])
        try add("演示", on: office, [
            ("DELL-1", 1, nil, [(finder, 1, 0)]), ("DELL-1", 2, nil, [(safari, 1, 0)]), ("DELL-1", 3, nil, []),
            ("DELL-1", 4, keynote, []), ("DELL-2", 1, nil, []), ("BUILTIN", 1, nil, [(notes, 2, 0)]),
        ])
        try add("写作", on: office, [
            ("DELL-1", 1, nil, [(pages, 1, 0)]), ("DELL-2", 1, nil, [(safari, 2, 0), (notes, 1, 0)]),
            ("BUILTIN", 1, nil, [(music, 1, 0)]),
        ])
        // 自动：办公室「工作」、家里「晚间」；办公室最近恢复「工作」
        try store.setAuto(true, presetID: work.id, topologyKey: office.identity.key)
        if let evening = store.topology(key: home.identity.key)?.presets.first(where: { $0.name == "晚间" }) {
            try store.setAuto(true, presetID: evening.id, topologyKey: home.identity.key)
        }
        try store.recordRestored(presetID: work.id, topologyKey: office.identity.key)
        try store.setAlias("家里", topologyKey: home.identity.key)
        try store.setAlias("内置 + DELL U2723QE ×2", topologyKey: office.identity.key)

        let names = [xcode: "Xcode", safari: "Safari", slack: "Slack", mail: "邮件", terminal: "终端", notion: "Notion",
                     keynote: "Keynote", music: "音乐", messages: "信息", notes: "备忘录", finder: "访达", pages: "Pages 文稿"]
        // 实时 Space：DELL #1 只有 2 个用户桌面 →「演示」（3 个）提示 Space 不足
        let live = [SpaceEntry(spaceID: 1, displayUUID: "DELL-1", index: 1, kind: SpaceKind.user),
                    SpaceEntry(spaceID: 2, displayUUID: "DELL-1", index: 2, kind: SpaceKind.user),
                    SpaceEntry(spaceID: 3, displayUUID: "DELL-2", index: 1, kind: SpaceKind.user),
                    SpaceEntry(spaceID: 4, displayUUID: "DELL-2", index: 2, kind: SpaceKind.user),
                    SpaceEntry(spaceID: 5, displayUUID: "BUILTIN", index: 1, kind: SpaceKind.user)]
        let dialogs = NoDialogs()
        let overwrite = OverwritePresetFlow(
            store: store,
            capture: { LayoutCapture(snapshot: Snapshot(capturedAt: clock.value, topology: [], spaces: [], windows: []),
                                     topology: office) },
            availability: { .available }, confirm: dialogs,
            captureExecutor: { $0() }, mainExecutor: { $0() })
        let presets = PresetManagerModel(store: store, topologyProvider: { office }, overwrite: overwrite,
                                         restore: { _, _ in }, dialogs: dialogs,
                                         currentSpaces: { live }, appName: { names[$0] })
        let ready = PermissionMonitor.Status(accessibilityGranted: true, screenCaptureGranted: true,
                                             screenCaptureNeedsReconfirm: false)
        let model = MainWindowModel(presets: presets, permissionStatus: ready, menuContent: { nil },
                                    openPermissionGuide: {},
                                    presetsFolder: PresetStore.defaultDirectory,
                                    logsFolder: SnapshotStore.defaultLogDirectory)
        return TopologyFixture(model: model, workID: work.id, homeKey: home.identity.key)
    }

    private func screens(_ list: [(String, String, CGRect, Bool)]) -> ObservedTopology {
        ObservedTopology(screens: list.map { uuid, name, frame, builtin in
            TopologyScreen(uuid: uuid, name: name, frame: frame,
                           pixelWidth: Int(frame.width), pixelHeight: Int(frame.height), rotation: 0,
                           isMirrored: false, isBuiltin: builtin)
        })
    }

    private func topology(_ screens: [(String, String, CGFloat)]) -> ObservedTopology {
        ObservedTopology(screens: screens.map { uuid, name, x in
            TopologyScreen(uuid: uuid, name: name, frame: CGRect(x: x, y: 0, width: x == 0 ? 1512 : 2560, height: 1440),
                           pixelWidth: 3024, pixelHeight: 1964, rotation: 0, isMirrored: false)
        })
    }

    // MARK: 渲染

    /// - Parameter scrollBy: 页面滚动视图下滚的点数（0 = 顶部）
    private func png<V: View>(_ view: V, dark: Bool, inactive: Bool, scrollBy: CGFloat = 0) throws -> Data {
        let size = MainWindowController.defaultSize
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        let host = NSHostingView(rootView: view.environment(\.controlActiveState, inactive ? .inactive : .key))
        let window = KeyWindow(contentRect: NSRect(x: -8000, y: -8000, width: size.width, height: size.height),
                               styleMask: MainWindowController.styleMask, backing: .buffered, defer: false)
        window.appearance = appearance
        let trafficLights = MainWindowController.install(host, in: window)
        window.setFrameOrigin(NSPoint(x: -8000, y: -8000))
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        if scrollBy > 0, let scrollView = Self.scrollViews(in: host).max(by: { $0.frame.width < $1.frame.width }) {
            let clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + scrollBy))
            scrollView.reflectScrolledClipView(clip)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        defer { window.orderOut(nil) }
        withExtendedLifetime(trafficLights) {}
        if let image = Self.composited(window) {
            return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        }
        let frameView = try XCTUnwrap(host.superview)  // 回退：整窗 frame view（无背景模糊）
        frameView.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                                 pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// 窗口服务器合成的窗口图（2x、不含阴影）。CGWindowListCreateImage 在 macOS 15 SDK 标为不可用（建议 ScreenCaptureKit，
    /// 但那要录屏权限）；取本进程自己的窗口仍可用且无需权限，故经 dlsym 调用。取不到返回 nil
    private static func composited(_ window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return nil }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3  // kCGWindowListOptionIncludingWindow
        let options: UInt32 = 1 << 0 | 1 << 3  // kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
        return createImage(.null, includingWindow, UInt32(window.windowNumber), options)?.takeRetainedValue()
    }

    /// 视图树里的滚动视图（最宽的是内容区页面，侧栏分组的较窄）
    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}
