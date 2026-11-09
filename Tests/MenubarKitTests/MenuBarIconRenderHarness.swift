import AppKit
import XCTest
@testable import MenubarKit

// MenuBarIconRenderHarness — 菜单栏图标三帧的离屏渲染（人工对照原型 menubar.png 用，UI 重构票 02）。
// 默认跳过；设环境变量 WINDUCTOR_MENUBAR_RENDER_DIR=<目录> 时渲染浅/深色菜单栏 × 三态各一张 PNG，外加一张对照总表
// （文件名前缀取 WINDUCTOR_MENUBAR_RENDER_PREFIX，默认 ui-menubar-）。
// 模板图着色用 NSImageView.contentTintColor = labelColor 近似系统菜单栏；菜单栏底色取原型同款近似值，无毛玻璃。
// 例：WINDUCTOR_MENUBAR_RENDER_DIR=/tmp swift test --filter MenuBarIconRenderHarness
final class MenuBarIconRenderHarness: XCTestCase {
    private let frames: [(String, MenuBarIconFrame)] = [("idle", .idle), ("restoring", .restoring),
                                                        ("notready", .notReady)]
    private let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
    /// 菜单栏高度（非刘海屏 24pt）与每个状态项槽宽
    private let barHeight: CGFloat = 24
    private let slotWidth: CGFloat = 44

    func testRenderMenuBarIcons() throws {
        guard let dir = ProcessInfo.processInfo.environment["WINDUCTOR_MENUBAR_RENDER_DIR"] else {
            throw XCTSkip("未设 WINDUCTOR_MENUBAR_RENDER_DIR：跳过离屏渲染")
        }
        let prefix = ProcessInfo.processInfo.environment["WINDUCTOR_MENUBAR_RENDER_PREFIX"] ?? "ui-menubar-"
        let images = try XCTUnwrap(MenuBarIconImages.make())
        print("menubar icon size", images.size)

        for (appearanceName, appearance) in appearances {
            for (frameName, frame) in frames {
                let bar = bar(appearance, slots: [images.image(for: frame)])
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)\(appearanceName)-\(frameName).png")
                try png(of: bar, appearance: appearance).write(to: url)
            }
        }
        try png(of: sheet(images), appearance: .aqua)
            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)sheet.png"))
    }

    /// 一段菜单栏：底色 + 每槽一个居中的状态项图标（模板图按外观着色）
    private func bar(_ appearance: NSAppearance.Name, slots: [NSImage]) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: slotWidth * CGFloat(slots.count), height: barHeight))
        view.appearance = NSAppearance(named: appearance)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: appearance == .darkAqua ? 0.17 : 0.93, alpha: 1).cgColor
        for (index, image) in slots.enumerated() {
            let imageView = NSImageView(image: image)
            imageView.contentTintColor = .labelColor
            imageView.frame = NSRect(x: slotWidth * CGFloat(index) + (slotWidth - image.size.width) / 2,
                                     y: (barHeight - image.size.height) / 2,
                                     width: image.size.width, height: image.size.height)
            view.addSubview(imageView)
        }
        return view
    }

    /// 对照总表：浅/深色两行三态 + 浅色放大 ×3 一行（版式同原型 menubar.png）
    private func sheet(_ images: MenuBarIconImages) -> NSView {
        let slots = frames.map { images.image(for: $0.1) }
        let zoom = images.size.height * 3 + 16
        let width = slotWidth * CGFloat(slots.count) * 2
        let sheet = NSView(frame: NSRect(x: 0, y: 0, width: width, height: barHeight * 2 + 24 + zoom))
        sheet.wantsLayer = true
        sheet.layer?.backgroundColor = NSColor.white.cgColor
        for (row, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let bar = bar(appearance, slots: slots)
            bar.frame = NSRect(x: 0, y: sheet.bounds.height - barHeight * CGFloat(row + 1) - 8 * CGFloat(row),
                               width: width, height: barHeight)
            bar.subviews.enumerated().forEach { index, view in
                view.frame.origin.x = slotWidth * 2 * CGFloat(index) + (slotWidth * 2 - view.frame.width) / 2
            }
            sheet.addSubview(bar)
        }
        for (index, image) in slots.enumerated() {
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.contentTintColor = .black
            let size = NSSize(width: image.size.width * 3, height: image.size.height * 3)
            imageView.frame = NSRect(x: slotWidth * 2 * CGFloat(index) + (slotWidth * 2 - size.width) / 2, y: 8,
                                     width: size.width, height: size.height)
            sheet.addSubview(imageView)
        }
        return sheet
    }

    /// 离屏无边框窗口宿主、2x 渲染
    private func png(of content: NSView, appearance: NSAppearance.Name) throws -> Data {
        let size = content.frame.size
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = content
        content.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                   pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        content.cacheDisplay(in: content.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
