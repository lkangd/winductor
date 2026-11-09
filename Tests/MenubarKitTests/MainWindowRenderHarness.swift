import AppKit
import Core
import SnapshotEngine
import SwiftUI
import XCTest
@testable import MenubarKit

// MainWindowRenderHarness — 统一主窗口的离屏渲染（人工与原型 PNG 对照用，ui-refactor 票 03）。
// 默认跳过；设环境变量 WINDUCTOR_MAINWINDOW_RENDER_DIR=<目录> 时把通用页、关于页 × 浅/深色 × key/失焦渲染为 PNG
// （另附拓扑页占位一张；文件名前缀取 WINDUCTOR_MAINWINDOW_RENDER_PREFIX，默认 ui-main-）。
// 离屏做法同原型 Render.swift：可成为 key 的离屏无边框窗口 + controlActiveState 注入，2x cacheDisplay；红绿灯画占位。
// 例：WINDUCTOR_MAINWINDOW_RENDER_DIR=/tmp swift test --filter MainWindowRenderHarness
final class MainWindowRenderHarness: XCTestCase {
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
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
        model.selectCurrentTopology()
        try png(MainWindowView(model: model), dark: false, inactive: false)
            .write(to: output.appendingPathComponent("\(prefix)topology-placeholder-light-key.png"))
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

    private func topology(_ screens: [(String, String, CGFloat)]) -> ObservedTopology {
        ObservedTopology(screens: screens.map { uuid, name, x in
            TopologyScreen(uuid: uuid, name: name, frame: CGRect(x: x, y: 0, width: x == 0 ? 1512 : 2560, height: 1440),
                           pixelWidth: 3024, pixelHeight: 1964, rotation: 0, isMirrored: false)
        })
    }

    // MARK: 渲染

    private func png<V: View>(_ view: V, dark: Bool, inactive: Bool) throws -> Data {
        let size = MainWindowController.defaultSize
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        let host = NSHostingView(rootView: view
            .environment(\.controlActiveState, inactive ? .inactive : .key)
            .environment(\.drawsTrafficLightPlaceholder, true))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        let window = KeyWindow(contentRect: NSRect(x: -8000, y: -8000, width: size.width, height: size.height),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                                 pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
