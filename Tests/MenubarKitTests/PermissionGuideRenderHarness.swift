import AppKit
import SwiftUI
import XCTest
@testable import MenubarKit

// PermissionGuideRenderHarness — 授权窗内容视图的离屏渲染（人工对照原型 perm-*.png 用，ui-refactor 票 05）。
// 默认跳过；设环境变量 WINDUCTOR_PERMISSION_RENDER_DIR=<目录> 时渲染 未授权 / 已授权一项 / 两项齐备（需重启）/
// 启动即就绪（无需重启，评审修复）× 浅/深色 各一张 PNG
//（文件名前缀取 WINDUCTOR_PERMISSION_RENDER_PREFIX，默认 ui-perm-）。
// 离屏技巧（票 09 改为忠实真窗口几何）：与真窗口同 styleMask / 配置（PermissionGuideWindow.install）的离屏标题栏窗口，
// 内容视图注入 controlActiveState=.key（控件画成激活态），对整窗 frame view 做 2x cacheDisplay——
// 标题栏高度、宿主安全区设置、真红绿灯（系统按钮，离屏未激活时画成灰色）都与真窗口一致。
// 例：WINDUCTOR_PERMISSION_RENDER_DIR=/tmp swift test --filter PermissionGuideRenderHarness
final class PermissionGuideRenderHarness: XCTestCase {
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    /// （文件名, 辅助功能, 屏幕录音, 本次运行中出现过未就绪）
    private let cases: [(String, Bool, Bool, Bool)] = [("0-none", false, false, true), ("1-partial", true, false, true),
                                                       ("2-ready", true, true, true),
                                                       ("3-already-ready", true, true, false)]

    func testRenderPermissionWindowCases() throws {
        guard let dir = ProcessInfo.processInfo.environment["WINDUCTOR_PERMISSION_RENDER_DIR"] else {
            throw XCTSkip("未设 WINDUCTOR_PERMISSION_RENDER_DIR：跳过离屏渲染")
        }
        let prefix = ProcessInfo.processInfo.environment["WINDUCTOR_PERMISSION_RENDER_PREFIX"] ?? "ui-perm-"
        for (name, accessibility, screenCapture, hasBeenNotReady) in cases {
            let status = PermissionMonitor.Status(accessibilityGranted: accessibility,
                                                  screenCaptureGranted: screenCapture,
                                                  screenCaptureNeedsReconfirm: false)
            let model = PermissionGuideModel(state: PermissionGuideState(status: status, hasBeenNotReady: hasBeenNotReady),
                                             openSettings: { _ in }, relaunch: {})
            for (appearanceName, dark) in [("light", false), ("dark", true)] {
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)\(name)-\(appearanceName).png")
                try png(PermissionGuideView(model: model), dark: dark).write(to: url)
            }
        }
    }

    private func png(_ view: PermissionGuideView, dark: Bool) throws -> Data {
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        let host = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
        let window = KeyWindow(contentRect: NSRect(x: -8000, y: -8000, width: PermissionGuideMetrics.width, height: 300),
                               styleMask: PermissionGuideWindow.styleMask, backing: .buffered, defer: false)
        window.appearance = appearance
        PermissionGuideWindow.install(host, in: window)
        window.setFrameOrigin(NSPoint(x: -8000, y: -8000))
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let frameView = try XCTUnwrap(host.superview)  // 整窗 frame view：含标题栏与红绿灯
        frameView.layoutSubtreeIfNeeded()

        let size = frameView.bounds.size
        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                                 pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        window.orderOut(nil)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
