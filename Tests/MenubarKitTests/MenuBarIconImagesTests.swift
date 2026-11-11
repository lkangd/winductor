import AppKit
import XCTest
@testable import MenubarKit

// UI 重构票 02：菜单栏图标图像（ui-refactor spec §4.1 / §4.2）。
// 接缝：MenuBarIconImages.make（SVG 直接生成 1x/2x → 共用裁切框的三帧模板图）。
// 独立事实来源：原型实测尺寸 21×22pt；徽记口径「先挖一圈透明，再画实心圆并挖出 !」——按像素断言。
final class MenuBarIconImagesTests: XCTestCase {
    private let frames: [MenuBarIconFrame] = [.idle, .restoring, .notReady]

    private func images() throws -> MenuBarIconImages {
        try XCTUnwrap(MenuBarIconImages.make(), "仓库 Resources/Brand 三态倍率图应可加载")
    }

    /// 三帧都是模板图（系统着色、明暗自适应），含徽记帧
    func testAllFramesAreTemplateImages() throws {
        let images = try images()
        for frame in frames {
            XCTAssertTrue(images.image(for: frame).isTemplate, "\(frame)")
        }
    }

    /// 三帧同尺寸（共用裁切框，切换不跳位），18pt × 1.35 裁切后约 21×22pt（原型实测）
    func testFramesShareSizeOfPrototype() throws {
        let images = try images()
        for frame in frames {
            XCTAssertEqual(images.image(for: frame).size, NSSize(width: 21, height: 22), "\(frame)")
        }
    }

    /// 主体（常态窗口组）在图像里竖直居中：上下留白相等（±0.5pt），两态切换不跳位
    func testIdleBodyIsVerticallyCentered() throws {
        let images = try images()
        let body = images.bodyRect
        XCTAssertEqual(body.minY, images.size.height - body.maxY, accuracy: 0.5)
    }

    /// 帧图缓存：同一帧反复取是同一实例（0.6s 交替不重新生成 / 读盘）
    func testFramesAreCached() throws {
        let images = try images()
        for frame in frames {
            XCTAssertTrue(images.image(for: frame) === images.image(for: frame), "\(frame)")
        }
    }

    func testExplicitRepresentationsAndTransparentBackgroundAtBothScales() throws {
        let images = try images()
        for frame in frames {
            let image = images.image(for: frame)
            let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
            XCTAssertEqual(reps.count, 2)
            XCTAssertEqual(reps.map(\.pixelsWide).sorted(), [21, 42])
            for rep in reps {
                XCTAssertEqual(rep.size, NSSize(width: 21, height: 22))
                XCTAssertEqual(rep.pixelsHigh * 21, rep.pixelsWide * 22)
                XCTAssertTrue(rep.hasAlpha)
                for (x, y) in [(0, 0), (rep.pixelsWide - 1, 0), (0, rep.pixelsHigh - 1), (rep.pixelsWide - 1, rep.pixelsHigh - 1)] {
                    XCTAssertEqual(rep.colorAt(x: x, y: y)?.alphaComponent, 0)
                }
                // The common crop leaves no fully opaque pixel touching a frame edge.
                let edges = (0..<rep.pixelsWide).flatMap { [($0, 0), ($0, rep.pixelsHigh - 1)] }
                    + (0..<rep.pixelsHigh).flatMap { [(0, $0), (rep.pixelsWide - 1, $0)] }
                XCTAssertTrue(edges.allSatisfy { (rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 1) < 0.9 }, "\(frame) edge clipping")
            }
        }
    }

    func testWindowBodiesStayPixelAlignedBetweenIdleAndRestoringAtBothScales() throws {
        for scale in [1, 2] {
            let idle = try XCTUnwrap(BrandAssets.menuBarRepresentation(.idle, scale: scale))
            let restoring = try XCTUnwrap(BrandAssets.menuBarRepresentation(.restoring, scale: scale))
            // Left satellite window is unchanged in the SVG, away from rays and interior restore arrows.
            for y in (10 * scale)..<(17 * scale) {
                for x in 0..<(4 * scale) {
                    XCTAssertEqual(idle.colorAt(x: x, y: y)?.alphaComponent ?? 0,
                                   restoring.colorAt(x: x, y: y)?.alphaComponent ?? 0, accuracy: 0.01)
                }
            }
        }
    }

    /// 徽记半径约 3.6pt，不随图形倍率放大
    func testBadgeRadius() {
        XCTAssertEqual(MenuBarIconImages.badgeRadius, 3.6, accuracy: 0.1)
    }

    /// 徽记形态（1x/2x 像素）：圆盘不透明；「!」竖笔与点被挖空；圆外一圈镂空（常态图同处原本不透明）；
    /// 徽记锚定主体右下角（圆心落在主体框内靠右下）；徽记之外与常态图一致
    func testNotReadyBadgeIsKnockedOutExclamation() throws {
        let images = try images()
        for scale: CGFloat in [1, 2] {
            let idle = render(images.image(for: .idle), scale: scale)
            let badge = render(images.image(for: .notReady), scale: scale)
            let center = images.badgeCenter
            let radius = MenuBarIconImages.badgeRadius
            let body = images.bodyRect

            XCTAssertTrue(body.contains(center), "圆心应落在主体框内（锚主体右下角，不是画布角）")
            XCTAssertGreaterThan(center.x, body.midX)
            XCTAssertLessThan(center.y, body.midY)

            XCTAssertGreaterThan(alpha(badge, center.x + 2.2, center.y), 0.9, "圆盘应实心")
            XCTAssertLessThan(alpha(badge, center.x, center.y + 1.2), 0.1, "「!」竖笔应挖空")
            // A 1px circular knockout retains antialiased corner coverage.
            XCTAssertLessThan(alpha(badge, center.x, center.y - 1.65), scale == 1 ? 0.35 : 0.1, "「!」点应挖空")

            let ring = CGPoint(x: center.x - radius - 0.55, y: center.y)
            XCTAssertGreaterThan(alpha(idle, ring.x, ring.y), 0.9, "常态图该处应为主体（测试取点前提）")
            // At 1x the 1.1pt curved ring straddles pixel edges; it must still visibly separate the badge.
            XCTAssertLessThan(alpha(badge, ring.x, ring.y), scale == 1 ? 0.55 : 0.1, "徽记外圈应镂空")

            let farPoint = CGPoint(x: body.minX + 3, y: body.midY)
            XCTAssertEqual(alpha(badge, farPoint.x, farPoint.y), alpha(idle, farPoint.x, farPoint.y), accuracy: 0.01)
        }
    }

    /// 原图缺失（如 .app 漏拷）：make 返回 nil，由调用方回落
    func testMissingSourcesReturnNil() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("winductor-empty-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: empty.appendingPathComponent("Contents/Resources"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let bundle = try XCTUnwrap(Bundle(url: empty))
        XCTAssertNil(MenuBarIconImages.make(bundle: bundle))
    }

    // MARK: 像素读取（1x/2x，坐标 pt、y 向上）

    private func render(_ image: NSImage, scale: CGFloat = 2) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale),
                                   pixelsHigh: Int(image.size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func alpha(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> CGFloat {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let px = Int(x * scale)
        let py = rep.pixelsHigh - 1 - Int(y * scale)
        return rep.colorAt(x: px, y: py)?.alphaComponent ?? 0
    }
}
