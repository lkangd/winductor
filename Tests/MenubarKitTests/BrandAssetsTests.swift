import AppKit
import XCTest
@testable import MenubarKit

// UI 重构票 01：品牌资源入口（ui-refactor spec §3）；票 08：应用图标改由透明底主体派生。
// 接缝：BrandAssets 的公开加载入口——菜单栏两态原图、透明底主体、界面用白底圆角图标。
// 独立事实来源：素材本体（菜单栏两态 128px RGBA；AppIconSubject.png 841×696 RGBA，已裁到 alpha 外接框），测试自带期望数值。
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

    /// 透明底主体：841×696 带 alpha，逻辑尺寸 = 像素尺寸；外接框外的白底已去除（四角透明），
    /// 主体内部的白色元素保留不透明（领结、窗口圆点、脸）
    func testAppIconSubjectIsTransparentWithInteriorWhitesKept() throws {
        let image = try XCTUnwrap(BrandAssets.appIconSubject())
        XCTAssertEqual(image.size, NSSize(width: 841, height: 696))
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertTrue(rep.hasAlpha)
        let last = (x: rep.pixelsWide - 1, y: rep.pixelsHigh - 1)
        for (x, y) in [(0, 0), (last.x, 0), (0, last.y), (last.x, last.y), (590, 40)] {
            XCTAssertEqual(alpha(rep, x, y), 0, accuracy: 0.01, "(\(x),\(y)) 应是去掉的白底")
        }
        for (x, y, what) in [(410, 600, "领结"), (65, 305, "绿窗圆点"), (400, 500, "脸")] {
            let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01, "\(what)应不透明")
            XCTAssertGreaterThan(color.brightnessComponent, 0.9, "\(what)应保留白色")
        }
    }

    /// 已裁到 alpha 外接框：四条边上都有不透明度 > 0 的像素（没有多余透明留白）
    func testAppIconSubjectIsTrimmedToAlphaBounds() throws {
        let rep = try XCTUnwrap(BrandAssets.appIconSubject()?.representations.first as? NSBitmapImageRep)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let edges: [(String, [(Int, Int)])] = [
            ("上", (0 ..< w).map { ($0, 0) }), ("下", (0 ..< w).map { ($0, h - 1) }),
            ("左", (0 ..< h).map { (0, $0) }), ("右", (0 ..< h).map { (w - 1, $0) }),
        ]
        for (name, points) in edges {
            XCTAssertTrue(points.contains { alpha(rep, $0.0, $0.1) > 0 }, "\(name)边全透明 = 未裁切")
        }
    }

    /// 同一资源目录只解码一次（缓存）
    func testAppIconSubjectIsCached() throws {
        let first = try XCTUnwrap(BrandAssets.appIconSubject())
        XCTAssertTrue(first === BrandAssets.appIconSubject())
    }

    /// 按边长取图：关于页 36pt、授权窗 64pt（spec §3）——尺寸正好等于请求边长
    func testAppIconHasRequestedSide() throws {
        for side: CGFloat in [36, 64] {
            let image = try XCTUnwrap(BrandAssets.appIcon(side: side))
            XCTAssertEqual(image.size, NSSize(width: side, height: side))
        }
    }

    /// 裁圆角（半径 = 边长 × 0.225）、不描边：四角透明；中心与四边中点不透明且是白底（无深色描边、无内缩）
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

    /// .app 内：从 Contents/Resources 读两态 PNG 与 AppIconSubject.png（make-app.sh 的产物布局）
    func testInsideAppBundleLoadsFromContentsResources() throws {
        let app = try makeFakeApp(populated: true)
        let bundle = try XCTUnwrap(Bundle(url: app))
        for art in BrandAssets.MenuBarArt.allCases {
            let rep = try XCTUnwrap(BrandAssets.menuBarSource(art, bundle: bundle), "\(art)")
            XCTAssertEqual(rep.pixelsWide, 128)
        }
        let subject = try XCTUnwrap(BrandAssets.appIconSubject(bundle: bundle))
        XCTAssertEqual(subject.size, NSSize(width: 841, height: 696))
        let icon = try XCTUnwrap(BrandAssets.appIcon(side: 64, bundle: bundle))
        XCTAssertEqual(icon.size, NSSize(width: 64, height: 64))
    }

    /// .app 内缺资源 → 加载失败，不回落仓库源码树（否则开发机上会掩盖打包漏拷）
    func testInsideAppBundleDoesNotFallBackToSourceTree() throws {
        let app = try makeFakeApp(populated: false)
        let bundle = try XCTUnwrap(Bundle(url: app))
        XCTAssertNil(BrandAssets.menuBarSource(.idle, bundle: bundle))
        XCTAssertNil(BrandAssets.appIconSubject(bundle: bundle))
        XCTAssertNil(BrandAssets.appIcon(side: 36, bundle: bundle))
    }

    /// 打包门禁：现代图标仍走 Composer；传统通知消费者有完整档位的独立 icns。
    /// WINDUCTOR_APP_BUNDLE_PATH=<app> swift test --filter testPackagedAppHasCompleteLegacyIcon
    func testPackagedAppHasCompleteLegacyIcon() throws {
        guard let path = ProcessInfo.processInfo.environment["WINDUCTOR_APP_BUNDLE_PATH"] else {
            throw XCTSkip("未指定待验收 app")
        }
        let bundle = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String, "AppIcon")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String, "AppIconLegacy")
        let file = try XCTUnwrap(bundle.url(forResource: "AppIconLegacy", withExtension: "icns"))
        let reps = try XCTUnwrap(NSImageRep.imageReps(withContentsOf: file))
        XCTAssertEqual(Set(reps.map(\.pixelsWide)), [16, 32, 64, 128, 256, 512, 1024])
        for rep in reps {
            XCTAssertEqual(rep.pixelsWide, rep.pixelsHigh)
        }
        let image = try XCTUnwrap(NSImage(contentsOf: file))
        image.size = NSSize(width: 64, height: 64)
        let bitmap = render(image, scale: 1)
        let colorful = (0..<64).reduce(0) { count, y in
            count + (0..<64).filter { x in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return color.alphaComponent > 0.9 && color.saturationComponent > 0.25
            }.count
        }
        XCTAssertGreaterThan(colorful, 200, "必须含彩色品牌主体，不能是空白或通用网格占位图")
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

    /// 临时伪 .app：populated 时按 make-app.sh 布局放两态 PNG 与透明底主体
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
        let subject = BrandAssets.appIconSubjectFileName
        try fm.copyItem(at: source.appendingPathComponent(subject), to: resources.appendingPathComponent(subject))
        return app
    }
}
