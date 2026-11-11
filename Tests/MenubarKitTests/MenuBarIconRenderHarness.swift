import AppKit
import XCTest
@testable import MenubarKit

/// Exact-size, pixel-aligned template previews; approximate bar colors, not a live status bar.
final class MenuBarIconRenderHarness: XCTestCase {
    func testRenderMenuBarIcons() throws {
        guard let dir = ProcessInfo.processInfo.environment["WINDUCTOR_MENUBAR_RENDER_DIR"] else {
            throw XCTSkip("未设 WINDUCTOR_MENUBAR_RENDER_DIR：跳过离屏渲染")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let images = try XCTUnwrap(MenuBarIconImages.make())
        for scale in [1, 2] {
            for dark in [false, true] {
                for (name, frame) in [("idle", MenuBarIconFrame.idle), ("restoring", .restoring), ("notready", .notReady)] {
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 44 * scale,
                        pixelsHigh: 24 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    rep.size = NSSize(width: 44, height: 24)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    NSColor(white: dark ? 0.17 : 0.93, alpha: 1).setFill()
                    NSRect(x: 0, y: 0, width: 44, height: 24).fill()
                    let image = images.image(for: frame).copy() as! NSImage
                    image.isTemplate = false
                    let rect = NSRect(x: 11, y: 1, width: 21, height: 22)
                    NSGraphicsContext.current!.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
                    image.draw(in: rect)
                    (dark ? NSColor.white : NSColor.black).setFill()
                    rect.fill(using: .sourceIn)
                    NSGraphicsContext.current!.cgContext.endTransparencyLayer()
                    NSGraphicsContext.restoreGraphicsState()
                    let file = "\(dark ? "dark" : "light")-\(name)-\(scale)x.png"
                    try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
                }
            }
        }
    }
}
