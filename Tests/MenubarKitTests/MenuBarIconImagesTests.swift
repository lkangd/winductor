import AppKit
import XCTest
@testable import MenubarKit

// UI 重构票 02：菜单栏图标图像（ui-refactor spec §4.1 / §4.2）。
// 接缝：MenuBarIconImages.make（两态 128px 原图 → 共用裁切框、18pt × 1.35 的三帧模板图）。
// 独立事实来源：原型实测尺寸 21×22pt；徽记口径「先挖一圈透明，再画实心圆并挖出 !」——按像素断言。
final class MenuBarIconImagesTests: XCTestCase {
    private let frames: [MenuBarIconFrame] = [.idle, .restoring, .notReady]

    private func images() throws -> MenuBarIconImages {
        try XCTUnwrap(MenuBarIconImages.make(), "仓库 Resources/Brand 两态原图应可加载")
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

    /// 徽记半径约 3.6pt，不随图形倍率放大
    func testBadgeRadius() {
        XCTAssertEqual(MenuBarIconImages.badgeRadius, 3.6, accuracy: 0.1)
    }

    /// 徽记形态（2x 像素）：圆盘不透明；「!」竖笔与点被挖空；圆外一圈镂空（常态图同处原本不透明）；
    /// 徽记锚定主体右下角（圆心落在主体框内靠右下）；徽记之外与常态图一致
    func testNotReadyBadgeIsKnockedOutExclamation() throws {
        let images = try images()
        let idle = render(images.image(for: .idle))
        let badge = render(images.image(for: .notReady))
        let center = images.badgeCenter
        let radius = MenuBarIconImages.badgeRadius
        let body = images.bodyRect

        XCTAssertTrue(body.contains(center), "圆心应落在主体框内（锚主体右下角，不是画布角）")
        XCTAssertGreaterThan(center.x, body.midX)
        XCTAssertLessThan(center.y, body.midY)

        XCTAssertGreaterThan(alpha(badge, center.x + 2.2, center.y), 0.9, "圆盘应实心")
        XCTAssertLessThan(alpha(badge, center.x, center.y + 1.2), 0.1, "「!」竖笔应挖空")
        XCTAssertLessThan(alpha(badge, center.x, center.y - 1.65), 0.1, "「!」点应挖空")

        let ring = CGPoint(x: center.x - radius - 0.55, y: center.y)
        XCTAssertGreaterThan(alpha(idle, ring.x, ring.y), 0.9, "常态图该处应为主体（测试取点前提）")
        XCTAssertLessThan(alpha(badge, ring.x, ring.y), 0.1, "徽记外圈应镂空")

        let farPoint = CGPoint(x: body.minX + 3, y: body.midY)
        XCTAssertEqual(alpha(badge, farPoint.x, farPoint.y), alpha(idle, farPoint.x, farPoint.y), accuracy: 0.01)
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

    // MARK: 像素读取（2x，坐标 pt、y 向上）

    private func render(_ image: NSImage) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 2),
                                   pixelsHigh: Int(image.size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
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
        let px = Int(x * 2)
        let py = rep.pixelsHigh - 1 - Int(y * 2)
        return rep.colorAt(x: px, y: py)?.alphaComponent ?? 0
    }
}
