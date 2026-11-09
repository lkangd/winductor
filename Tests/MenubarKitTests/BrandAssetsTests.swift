import AppKit
import XCTest
@testable import MenubarKit

// UI 重构票 01：品牌资源入口（ui-refactor spec §3）。
// 接缝：BrandAssets 的公开加载入口——菜单栏两态原图、应用图标（原图 / 按边长裁连续圆角）。
// 独立事实来源：素材本体（菜单栏两态 128px RGBA；appiconset 10 张 16–1024px），测试自带期望数值。
// 资源位置两路：swift test / swift run（非 .app）读仓库 Resources/Brand；.app 内只读 Contents/Resources，
// 不回落源码树（打包漏拷须暴露为加载失败）——用临时伪 .app 覆盖后一路。
final class BrandAssetsTests: XCTestCase {
    // MARK: 菜单栏两态原图

    /// 两态原图都能加载：128×128 px、带 alpha（模板图 = 黑 + 透明）
    func testMenuBarSourcesLoadAt128PixelsWithAlpha() throws {
        for art in BrandAssets.MenuBarArt.allCases {
            let rep = try XCTUnwrap(BrandAssets.menuBarSource(art), "\(art) 未加载")
            XCTAssertEqual(rep.pixelsWide, 128, "\(art)")
            XCTAssertEqual(rep.pixelsHigh, 128, "\(art)")
            XCTAssertTrue(rep.hasAlpha, "\(art)")
        }
    }

    /// 两态是不同的图（恢复中多出光芒/箭头），防止两态误指同一文件
    func testMenuBarSourcesDiffer() throws {
        let idle = try XCTUnwrap(BrandAssets.menuBarSource(.idle))
        let restoring = try XCTUnwrap(BrandAssets.menuBarSource(.restoring))
        XCTAssertNotEqual(idle.representation(using: .png, properties: [:]),
                          restoring.representation(using: .png, properties: [:]))
    }

    // MARK: 应用图标

    /// 原图：多分辨率（16–1024 px 共 10 张），逻辑尺寸取最大点数 512pt
    func testAppIconSourceHasAllResolutions() throws {
        let image = try XCTUnwrap(BrandAssets.appIconSource())
        let pixelWidths = Set(image.representations.map(\.pixelsWide))
        XCTAssertEqual(pixelWidths, [16, 32, 64, 128, 256, 512, 1024])
        XCTAssertEqual(image.representations.count, 10)
        XCTAssertEqual(image.size, NSSize(width: 512, height: 512))
    }

    /// 按边长取图：关于页 36pt、授权窗 64pt（spec §3）——尺寸正好等于请求边长
    func testAppIconHasRequestedSide() throws {
        for side: CGFloat in [36, 64] {
            let image = try XCTUnwrap(BrandAssets.appIcon(side: side))
            XCTAssertEqual(image.size, NSSize(width: side, height: side))
        }
    }

    /// 裁圆角（半径 = 边长 × 0.225）、不描边：四角透明；中心与四边中点不透明且是原图白底（无深色描边、无内缩）
    func testAppIconIsClippedToRoundedCornersWithoutStroke() throws {
        let image = try XCTUnwrap(BrandAssets.appIcon(side: 36))
        let rep = render(image, scale: 2)
        let last = rep.pixelsWide - 1
        XCTAssertEqual(rep.pixelsWide, 72)

        for (x, y) in [(1, 1), (last - 1, 1), (1, last - 1), (last - 1, last - 1)] {
            XCTAssertEqual(alpha(rep, x, y), 0, accuracy: 0.01, "角 (\(x),\(y)) 应透明")
        }
        XCTAssertEqual(alpha(rep, 36, 36), 1, accuracy: 0.01, "中心应不透明")
        for (x, y) in [(36, 0), (36, last), (0, 36), (last, 36)] {
            let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(color.alphaComponent, 0.9, "边中点 (\(x),\(y)) 应贴边不透明")
            XCTAssertGreaterThan(color.brightnessComponent, 0.85, "边中点 (\(x),\(y)) 应是白底而非描边")
        }
    }

    // MARK: .app 内的资源位置

    /// .app 内：从 Contents/Resources 读两态 PNG 与 AppIcon.icns（make-app.sh 的产物布局）
    func testInsideAppBundleLoadsFromContentsResources() throws {
        let app = try makeFakeApp(populated: true)
        let bundle = try XCTUnwrap(Bundle(url: app))
        for art in BrandAssets.MenuBarArt.allCases {
            let rep = try XCTUnwrap(BrandAssets.menuBarSource(art, bundle: bundle), "\(art)")
            XCTAssertEqual(rep.pixelsWide, 128)
        }
        let source = try XCTUnwrap(BrandAssets.appIconSource(bundle: bundle))
        XCTAssertEqual(source.representations.map(\.pixelsWide).max(), 1024)
        let icon = try XCTUnwrap(BrandAssets.appIcon(side: 64, bundle: bundle))
        XCTAssertEqual(icon.size, NSSize(width: 64, height: 64))
    }

    /// .app 内缺资源 → 加载失败，不回落仓库源码树（否则开发机上会掩盖打包漏拷）
    func testInsideAppBundleDoesNotFallBackToSourceTree() throws {
        let app = try makeFakeApp(populated: false)
        let bundle = try XCTUnwrap(Bundle(url: app))
        XCTAssertNil(BrandAssets.menuBarSource(.idle, bundle: bundle))
        XCTAssertNil(BrandAssets.appIconSource(bundle: bundle))
        XCTAssertNil(BrandAssets.appIcon(side: 36, bundle: bundle))
    }

    // MARK: - 辅助

    private func render(_ image: NSImage, scale: CGFloat) -> NSBitmapImageRep {
        let pixels = Int(image.size.width * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        rep.colorAt(x: x, y: y)?.alphaComponent ?? -1
    }

    /// 临时伪 .app：populated 时按 make-app.sh 布局放两态 PNG 与 iconutil 生成的 AppIcon.icns
    private func makeFakeApp(populated: Bool) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("BrandAssetsTests-\(UUID().uuidString)")
        addTeardownBlock { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("Fake.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "test.fake", "CFBundlePackageType": "APPL"]
        try (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"))
        guard populated else { return app }

        let source = BrandAssets.sourceTreeDirectory
        for art in BrandAssets.MenuBarArt.allCases {
            let name = BrandAssets.menuBarFileName(art)
            try fm.copyItem(at: source.appendingPathComponent(name), to: resources.appendingPathComponent(name))
        }
        let iconset = root.appendingPathComponent("AppIcon.iconset")
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        let appiconset = source.appendingPathComponent("AppIcon.appiconset")
        for file in try fm.contentsOfDirectory(atPath: appiconset.path) where file.hasSuffix(".png") {
            try fm.copyItem(at: appiconset.appendingPathComponent(file), to: iconset.appendingPathComponent(file))
        }
        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
        try iconutil.run()
        iconutil.waitUntilExit()
        XCTAssertEqual(iconutil.terminationStatus, 0, "iconutil 失败")
        return app
    }
}
