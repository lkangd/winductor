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

    /// 黑白阶跃背景：量化 header 的 10%→90% 亮度过渡宽度，避免把透明度误当模糊半径。
    func testRenderHeaderBlurProfile() throws {
        guard let dir = ProcessInfo.processInfo.environment["WINDUCTOR_MAINWINDOW_RENDER_DIR"] else {
            throw XCTSkip("未指定渲染目录")
        }
        let view = ZStack(alignment: .top) {
            HStack(spacing: 0) { Color.black; Color.white }
            MainWindowHeader()
                .background {
                    HeaderBackdrop {
                        HStack(spacing: 0) { Color.black; Color.white }
                    }
                }
        }
        .ignoresSafeArea()
        let data = try png(view, dark: false, inactive: false)
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ui-header-blur-profile.png"))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        let scale = CGFloat(rep.pixelsWide) / MainWindowController.defaultSize.width
        let row = Int(25 * scale)
        let values = (0..<rep.pixelsWide).map { x -> CGFloat in
            guard let c = rep.colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB) else { return 0 }
            return (c.redComponent + c.greenComponent + c.blueComponent) / 3
        }
        let center = rep.pixelsWide / 2
        let low = values[center - 150], high = values[center + 150]
        let left = try XCTUnwrap((center - 140..<center + 140).first { values[$0] >= low + (high - low) * 0.1 })
        let right = try XCTUnwrap((center - 140..<center + 140).first { values[$0] >= low + (high - low) * 0.9 })
        print("[header-blur-profile] transition10to90=\(CGFloat(right - left) / scale)pt; sigma≈\(CGFloat(right - left) / scale / 2.563)pt")
        let transition = CGFloat(right - left) / scale
        XCTAssertEqual(transition, 43.5 * 0.5, accuracy: 1.5, "原玻璃实测 43.5pt；新高斯过渡宽度应减半")
    }

    /// header 左侧/底部与内容区左线同色同宽；左下角不允许两条半透明线重复叠色。
    func testRenderHeaderBordersMatchContentSeparator() throws {
        guard let dir = ProcessInfo.processInfo.environment["WINDUCTOR_MAINWINDOW_RENDER_DIR"] else {
            throw XCTSkip("未指定渲染目录")
        }
        let fixture = try makeTopologyFixture()
        fixture.model.select(.about)
        for dark in [false, true] {
            let data = try png(MainWindowView(model: fixture.model), dark: dark, inactive: false)
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ui-header-borders-\(dark ? "dark" : "light").png"))
            let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
            let scale = CGFloat(rep.pixelsWide) / MainWindowController.defaultSize.width
            let left = Int(MainWindowMetrics.sidebarWidth * scale)
            let bottom = Int(MainWindowMetrics.headerHeight * scale)
            func rgb(_ x: Int, _ y: Int) throws -> [CGFloat] {
                let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                return [color.redComponent, color.greenComponent, color.blueComponent]
            }
            let base = try rgb(left + Int(4 * scale), Int(25 * scale))
            let line = try rgb(left, Int(25 * scale))
            if !dark {
                let bodyBase = try rgb(left + Int(4 * scale), Int(80 * scale))
                for component in base + bodyBase {
                    XCTAssertEqual(component, 1, accuracy: 0.01, "浅色 header 与内容空白区均为纯白")
                }
            }
            XCTAssertGreaterThan(zip(base, line).map { abs($0 - $1) }.max() ?? 0, 0.03, "不能省掉边框")
            let samples = [(left, Int(80 * scale)), (left + Int(200 * scale), bottom - 1), (left, bottom - 1)]
            for (x, y) in samples {
                for (actual, expected) in zip(try rgb(x, y), line) {
                    XCTAssertEqual(actual, expected, accuracy: 0.01, "浅深色下，竖线/横线/交点同色")
                }
            }
            // 1pt = scale 个物理像素；内侧紧邻像素应回到页面底色。
            for (actual, expected) in zip(try rgb(left + Int(scale), Int(25 * scale)), base) {
                XCTAssertEqual(actual, expected, accuracy: 0.01, "左框只宽 1pt")
            }
            for (actual, expected) in zip(try rgb(left + Int(200 * scale), bottom - Int(scale) - 1), base) {
                XCTAssertEqual(actual, expected, accuracy: 0.01, "底框只高 1pt")
            }
        }
    }

    /// 测实际通用/关于页，不复制按钮实现；比较可见字形与按钮底框的上下中心。
    func testContentButtonLabelsAreVerticallyCentered() throws {
        guard let dir = ProcessInfo.processInfo.environment["WINDUCTOR_MAINWINDOW_RENDER_DIR"] else {
            throw XCTSkip("未指定渲染目录")
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = ProcessInfo.processInfo.environment["WINDUCTOR_APP_BUNDLE_PATH"].map(URL.init(fileURLWithPath:))
            ?? repo.appendingPathComponent("build/Winductor.app")
        let productSDK = try linkedSDK(app.appendingPathComponent("Contents/MacOS/Winductor"))
        let hostSDK = try linkedSDK(XCTUnwrap(Bundle.main.executableURL))
        guard hostSDK == productSDK else {
            throw XCTSkip("宿主 SDK \(hostSDK) ≠ 产品 SDK \(productSDK)，不能代替真机验收；请用 Scripts/test-mainwindow-render.sh")
        }
        let legacy = Int(productSDK.split(separator: ".")[0])! < 26
        let model = try makeModel()
        let cases: [(MainWindowPage, [(String, CGRect)])] = [
            (model.state.selection, [("保存当前布局", CGRect(x: 710, y: 323, width: 125, height: 33)),
                                     ("恢复", CGRect(x: 725, y: 376, width: 60, height: 32)),
                                     ("更多图标", CGRect(x: 785, y: 376, width: 50, height: 32))]),
            (.general, [("授权引导", CGRect(x: 458, y: 112, width: 97, height: 32)),
                        ("撤销", CGRect(x: 265, y: 304, width: 55, height: legacy ? 25 : 32)),
                        ("预设文件夹", CGRect(x: 250, y: legacy ? 434 : 438, width: 110, height: legacy ? 28 : 32)),
                        ("日志文件夹", CGRect(x: legacy ? 400 : 410, y: legacy ? 434 : 438, width: 110, height: legacy ? 28 : 32))]),
            (.about, [("发行说明", CGRect(x: 250, y: 221, width: 95, height: 33))]),
        ]
        for (page, buttons) in cases {
            model.select(page)
            for dark in [false, true] {
                let data = try png(MainWindowView(model: model), dark: dark, inactive: false)
                try data.write(to: URL(fileURLWithPath: dir)
                    .appendingPathComponent("ui-button-centers-\(page)-\(dark ? "dark" : "light").png"))
                let disabled = try png(MainWindowView(model: model).disabled(true), dark: dark, inactive: false)
                try disabled.write(to: URL(fileURLWithPath: dir)
                    .appendingPathComponent("ui-button-centers-\(page)-\(dark ? "dark" : "light")-disabled.png"))
                let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
                let scale = CGFloat(rep.pixelsHigh) / MainWindowController.defaultSize.height
                for (name, rect) in buttons {
                    func brightness(_ x: Int, _ y: Int) throws -> CGFloat {
                        let c = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        return (c.redComponent + c.greenComponent + c.blueComponent) / 3
                    }
                    let x0 = Int(rect.minX * scale), x1 = Int(rect.maxX * scale)
                    let y0 = Int(rect.minY * scale), y1 = Int(rect.maxY * scale)
                    let base = try brightness(x0, y0)
                    var faceRows: [Int] = [], inkRows: [Int] = []
                    for y in y0..<y1 {
                        for x in x0..<x1 {
                            let value = try brightness(x, y)
                            // 深色按钮比页面亮；反向的黑色投影不属于可见底框。
                            if (dark ? value - base : base - value) > 0.025 { faceRows.append(y) }
                            if dark ? value > 0.55 : value < 0.55 { inkRows.append(y) }
                        }
                    }
                    let faceTop = try XCTUnwrap(faceRows.min()), faceBottom = try XCTUnwrap(faceRows.max())
                    // Retina 深色原生按钮的外缘高光也可能很亮；只在底框内部找字形，不能把高光当成文字。
                    let chromeInset = Int(2 * scale)
                    inkRows.removeAll { $0 <= faceTop + chromeInset || $0 >= faceBottom - chromeInset }
                    let inkTop = try XCTUnwrap(inkRows.min()), inkBottom = try XCTUnwrap(inkRows.max())
                    let delta = CGFloat(inkTop + inkBottom - faceTop - faceBottom) / (2 * scale)
                    print("[button-centering] \(name) dark=\(dark) inkMinusFaceCenter=\(delta)pt")
                    XCTAssertEqual(delta, 0, accuracy: 0.5 / scale, "\(name)：可见文字应在按钮上下中心（允许半个物理像素的栅格化差异）")
                    if page == .about {
                        // 同一个真实发行说明按钮中，文字和小箭头分别对底框居中。
                        let parts = legacy ? [("文字", 260..<315), ("箭头", 316..<329)] : [("文字", 260..<318), ("箭头", 319..<332)]
                        for (part, range) in parts {
                            var rows: [Int] = []
                            for y in (faceTop + chromeInset + 1)..<(faceBottom - chromeInset) {
                                for x in Int(CGFloat(range.lowerBound) * scale)..<Int(CGFloat(range.upperBound) * scale) {
                                    let value = try brightness(x, y)
                                    if dark ? value > 0.55 : value < 0.55 { rows.append(y) }
                                }
                            }
                            let top = try XCTUnwrap(rows.min()), bottom = try XCTUnwrap(rows.max())
                            let partDelta = CGFloat(top + bottom - faceTop - faceBottom) / (2 * scale)
                            print("[button-centering] 发行说明\(part) dark=\(dark) inkMinusFaceCenter=\(partDelta)pt")
                            XCTAssertEqual(partDelta, 0, accuracy: 0.5 / scale, "发行说明\(part)应对按钮底框上下居中")
                        }
                    }
                }
            }
        }
    }

    func testContentButtonStyleKeepsActionsAndDisabledState() throws {
        // 覆盖此接缝的真实两类调用：普通文字按钮与纯图标按钮。删除确认仍走 NSAlert。
        for hasText in [true, false] {
            for enabled in [true, false] {
                var calls = 0
                let control = hasText
                    ? AnyView(Button("恢复") { calls += 1 }.contentButtonStyle())
                    : AnyView(Button { calls += 1 } label: {
                        Image(systemName: "ellipsis").frame(width: 16, height: 16)
                    }.contentButtonStyle())
                let button = control.disabled(!enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                let host = NSHostingView(rootView: button)
                let window = KeyWindow(contentRect: NSRect(x: -8000, y: -8000, width: 160, height: 60),
                                       styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                NSApplication.shared.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 80, y: 30),
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                    NSApplication.shared.sendEvent(event)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                window.orderOut(nil)
                XCTAssertEqual(calls, enabled ? 1 : 0, "hasText=\(hasText) enabled=\(enabled)：保留单次点击和禁用态")
            }
        }
    }

    func testEveryDisplayTileReceivesClicks() throws {
        try assertEveryTileReceivesClicks(portrait: false, width: 645)
        try assertEveryTileReceivesClicks(portrait: true, width: 505)
    }

    /// 真事件走 SwiftUI 命中测试：三屏上下排列 / 横竖混排，逐块点击中心并再次点击取消筛选。
    private func assertEveryTileReceivesClicks(portrait: Bool, width: CGFloat) throws {
        let fixture = try makeTopologyFixture(portrait: portrait)
        let fixtureDirectory = try XCTUnwrap(directory)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let model = fixture.model
        let selected = try XCTUnwrap(model.presets.state.selected)
        let size = CGSize(width: width, height: 150)
        let host = NSHostingView(rootView: ArrangementDiagram(state: model.presets.state,
            displays: selected.displays, isDimmed: false, onSelect: model.presets.selectDisplay))
        let window = KeyWindow(contentRect: NSRect(x: -8000, y: -8000, width: size.width, height: size.height),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let arranged = DisplayArrangementLayout.layout(selected.displays, in: size, padding: 16)
        for display in arranged {
            let point = NSPoint(x: display.rect.midX, y: size.height - display.rect.midY)
            for expected: String? in [display.uuid, nil] {
                for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                    NSApplication.shared.sendEvent(event)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                XCTAssertEqual(model.presets.state.selectedDisplayUUID, expected, "点击 \(display.uuid)")
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

    private func makeTopologyFixture(portrait: Bool = false) throws -> TopologyFixture {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("winductor-toporender-\(UUID().uuidString)", isDirectory: true)
        let clock = Unboxed(Date(timeIntervalSince1970: 1_794_148_200))
        let store = PresetStore(directory: directory, now: { clock.value })
        let office = portrait
            ? screens([("BUILTIN", "内置视网膜显示器", CGRect(x: 0, y: 0, width: 1512, height: 982), true),
                       ("DELL-1", "DELL P2419H", CGRect(x: 1512, y: 0, width: 1920, height: 1080), false),
                       ("DELL-2", "DELL P2419H", CGRect(x: 3432, y: -480, width: 1080, height: 1920), false)])
            : screens([("DELL-1", "DELL U2723QE", CGRect(x: 0, y: 0, width: 2560, height: 1440), false),
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

    /// AppKit/SwiftUI 的外观兼容路径由主可执行 SDK 标记决定，不能用新版 XCTest 外观代验旧 SDK 产品。
    private func linkedSDK(_ executable: URL) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        process.arguments = ["-l", executable.path]
        process.standardOutput = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            if fields.count == 2 && fields[0] == "sdk" { return String(fields[1]) }
        }
        XCTFail("主可执行缺少 SDK 标记：\(executable.path)")
        throw XCTSkip("无法核对 linked-SDK")
    }

    /// - Parameter scrollBy: 页面滚动视图下滚的点数（0 = 顶部）
    private func png<V: View>(_ view: V, dark: Bool, inactive: Bool, scrollBy: CGFloat = 0) throws -> Data {
        let size = MainWindowController.defaultSize
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        let host = NSHostingView(rootView: view.environment(\.controlActiveState, inactive ? .inactive : .key))
        let scaleSetting = ProcessInfo.processInfo.environment["WINDUCTOR_MAINWINDOW_RENDER_SCALE"]
        let wants1x = scaleSetting == "1"
        let wants2x = scaleSetting == "2"
        let screen = wants1x
            ? NSScreen.screens.filter { $0.backingScaleFactor == 1 }.max { $0.frame.maxY < $1.frame.maxY }
            : wants2x ? NSScreen.screens.filter { $0.backingScaleFactor == 2 }.min { $0.frame.minY < $1.frame.minY } : NSScreen.main
        if (wants1x || wants2x) && screen == nil { throw XCTSkip("没有请求倍率的真实屏幕，不能用缩图代替") }
        let window = KeyWindow(contentRect: NSRect(x: -8000, y: -8000, width: size.width, height: size.height),
                               styleMask: MainWindowController.styleMask, backing: .buffered, defer: false, screen: screen)
        window.appearance = appearance
        let trafficLights = MainWindowController.install(host, in: window)
        if wants1x, let screen {
            // 保留 1pt 在指定屏顶部（菜单栏下，窗口本身在屏外），否则全离屏会回落到 Retina backing。
            window.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - 1))
        } else if wants2x, let screen {
            window.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.minY - size.height + 1))
        } else {
            window.setFrameOrigin(NSPoint(x: -8000, y: -8000))
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        print("[render-environment] backingScale=\(window.backingScaleFactor) requested1x=\(wants1x)")
        if wants1x { XCTAssertEqual(window.backingScaleFactor, 1) }
        if wants2x { XCTAssertEqual(window.backingScaleFactor, 2) }
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

        let scale: CGFloat = ProcessInfo.processInfo.environment["WINDUCTOR_MAINWINDOW_RENDER_SCALE"] == "1" ? 1 : 2
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
        let resolution: UInt32 = ProcessInfo.processInfo.environment["WINDUCTOR_MAINWINDOW_RENDER_SCALE"] == "1" ? 1 << 4 : 1 << 3
        let options: UInt32 = 1 << 0 | resolution  // boundsIgnoreFraming + nominal/best resolution
        return createImage(.null, includingWindow, UInt32(window.windowNumber), options)?.takeRetainedValue()
    }

    /// 视图树里的滚动视图（最宽的是内容区页面，侧栏分组的较窄）
    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}
