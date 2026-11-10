import AppKit
import SwiftUI
import XCTest
@testable import MenubarKit

// PermissionGuideRenderHarness — 授权窗内容视图的离屏渲染（人工对照原型 perm-*.png 用，ui-refactor 票 05）。
// 默认跳过；设环境变量 WINDUCTOR_PERMISSION_RENDER_DIR=<目录> 时渲染 未授权 / 已授权一项 / 两项齐备（需重启）/
// 启动即就绪（无需重启，评审修复）× 浅/深色 各一张 PNG
//（文件名前缀取 WINDUCTOR_PERMISSION_RENDER_PREFIX，默认 ui-perm-）。
// 离屏技巧：可成为 key 的离屏无边框窗口 + controlActiveState=.key（控件画成激活态），2x cacheDisplay；
// 透明标题栏的红绿灯由真窗口提供，离屏时在左上角画静态占位，便于与原型对照。
// 例：WINDUCTOR_PERMISSION_RENDER_DIR=/tmp swift test --filter PermissionGuideRenderHarness
final class PermissionGuideRenderHarness: XCTestCase {
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    /// 离屏红绿灯占位（原型 FakeTrafficLights：上 14、左 24 + 6、直径 12、间距 8）
    private struct FakeTrafficLights: View {
        var body: some View {
            HStack(spacing: 8) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
            }
            .frame(width: 52, height: 12, alignment: .leading)
            .padding(.top, 14).padding(.leading, PermissionGuideMetrics.inset + 6)
        }
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
        let root = ZStack(alignment: .topLeading) {
            view
            FakeTrafficLights()
        }
        .environment(\.controlActiveState, .key)
        let host = NSHostingView(rootView: root)
        host.appearance = appearance
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = KeyWindow(contentRect: NSRect(x: -8000, y: -8000, width: size.width, height: size.height),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
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
