import AppKit

// MenuBarIconImages.swift — 菜单栏图标三帧模板图（UI 重构票 02，ui-refactor spec §4.1 / §4.2）。
// 数值取自原型 Prototypes/UIRefactor 的 Brand.swift（定稿 3719e9f）：
//   - 裁切框：两态共用，以常态主体（窗口组）竖直中心为轴上下对称，高度容得下恢复中向上伸出的光芒，水平取两态并集，四周各留 2px；
//   - 尺寸：素材 18pt 设计尺寸 × 1.35，裁切后取整（约 21×22pt）；
//   - 未就绪：常态图 + 主体右下角镂空「!」徽记（先挖一圈透明，再画实心圆并挖出「!」），半径约 3.6pt，不随倍率放大。
// 三帧均为模板图（isTemplate，系统着色、明暗自适应）。原图只在 make 时读一次，帧图生成后缓存在本实例里。

struct MenuBarIconImages {
    /// 图形倍率（相对素材 18pt 设计尺寸；用户实况选定）
    static let scale: CGFloat = 1.35
    /// 素材设计尺寸（pt）：128px 原图对应 18pt
    static let designPoints: CGFloat = 18
    /// 徽记尺寸系数（徽记不随图形倍率等比放大，只略增，避免盖住图形）
    private static let badgeGrowth: CGFloat = 1.1
    /// 徽记实心圆半径（pt）
    static let badgeRadius: CGFloat = 3.3 * badgeGrowth
    /// 徽记外圈镂空宽度（pt）
    private static let badgeRingWidth: CGFloat = badgeGrowth
    /// 求主体框的 alpha 阈值
    private static let alphaThreshold: UInt8 = 5

    /// 帧图尺寸（pt）
    let size: NSSize
    /// 常态主体在图像内的位置（pt，y 向上），徽记据此锚定
    let bodyRect: CGRect
    /// 徽记圆心（pt，y 向上）
    let badgeCenter: CGPoint

    private let idle: NSImage
    private let restoring: NSImage
    private let notReady: NSImage

    func image(for frame: MenuBarIconFrame) -> NSImage {
        switch frame {
        case .idle: idle
        case .restoring: restoring
        case .notReady: notReady
        }
    }

    /// 读两态原图并生成三帧；任一原图缺失或为空图返回 nil（调用方回落）
    static func make(bundle: Bundle = .main) -> MenuBarIconImages? {
        guard let idleRep = BrandAssets.menuBarSource(.idle, bundle: bundle)?.cgImage,
              let restoringRep = BrandAssets.menuBarSource(.restoring, bundle: bundle)?.cgImage else { return nil }
        return MenuBarIconImages(idleSource: idleRep, restoringSource: restoringRep)
    }

    init?(idleSource: CGImage, restoringSource: CGImage) {
        guard let body = Self.alphaBox(idleSource), let restoringBox = Self.alphaBox(restoringSource) else { return nil }
        // 裁切框（像素坐标，y 向下）
        let all = body.union(restoringBox)
        let half = max(body.midY - all.minY, all.maxY - body.midY) + 2
        let crop = CGRect(x: all.minX - 2, y: body.midY - half, width: all.width + 4, height: 2 * half)

        let ptPerPx = Self.designPoints * Self.scale / CGFloat(idleSource.width)
        let size = NSSize(width: (crop.width * ptPerPx).rounded(), height: (crop.height * ptPerPx).rounded())
        let kx = size.width / crop.width
        let ky = size.height / crop.height
        let bodyRect = CGRect(x: (body.minX - crop.minX) * kx, y: (crop.maxY - body.maxY) * ky,
                              width: body.width * kx, height: body.height * ky)
        let r = Self.badgeRadius
        let badgeCenter = CGPoint(x: min(bodyRect.maxX - r * 0.4, size.width - r - 0.2), y: bodyRect.minY + r * 0.4)

        self.size = size
        self.bodyRect = bodyRect
        self.badgeCenter = badgeCenter
        idle = Self.templateImage(size: size, description: "Winductor") { ctx, rect in
            Self.draw(idleSource, crop: crop, in: rect, ctx: ctx)
        }
        restoring = Self.templateImage(size: size, description: "Winductor（恢复中）") { ctx, rect in
            Self.draw(restoringSource, crop: crop, in: rect, ctx: ctx)
        }
        notReady = Self.templateImage(size: size, description: "Winductor（未就绪）") { ctx, rect in
            Self.draw(idleSource, crop: crop, in: rect, ctx: ctx)
            Self.drawBadge(at: badgeCenter, ctx: ctx)
        }
    }

    // MARK: 绘制

    /// 模板图：按绘制分辨率惰性重绘（1x/2x 都清晰），透明层内绘制以便 .clear 挖空只作用于本图
    private static func templateImage(size: NSSize, description: String,
                                      draw: @escaping (CGContext, CGRect) -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            draw(ctx, rect)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    /// 把原图的 crop 区（像素，y 向下）映射到 rect（越界部分即透明）
    private static func draw(_ source: CGImage, crop: CGRect, in rect: CGRect, ctx: CGContext) {
        let sx = rect.width / crop.width
        let sy = rect.height / crop.height
        let full = CGRect(x: rect.minX - crop.minX * sx,
                          y: rect.minY - (CGFloat(source.height) - crop.maxY) * sy,
                          width: CGFloat(source.width) * sx, height: CGFloat(source.height) * sy)
        ctx.interpolationQuality = .high
        ctx.draw(source, in: full)
    }

    /// 镂空「!」徽记：先挖一圈透明，再画实心圆并挖出「!」（竖笔 + 点）
    private static func drawBadge(at c: CGPoint, ctx: CGContext) {
        let r = badgeRadius
        let k = badgeGrowth
        let ring = r + badgeRingWidth
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: c.x - ring, y: c.y - ring, width: 2 * ring, height: 2 * ring))
        ctx.restoreGState()

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))

        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fill(CGRect(x: c.x - 0.55 * k, y: c.y - 0.3 * k, width: 1.1 * k, height: 2.6 * k))
        ctx.fillEllipse(in: CGRect(x: c.x - 0.6 * k, y: c.y - 2.1 * k, width: 1.2 * k, height: 1.2 * k))
        ctx.restoreGState()
    }

    // MARK: 主体框

    /// 不透明像素的包围框（像素坐标，原点左上、y 向下）；全透明返回 nil。
    /// 先画进 8 位纯 alpha 缓冲，避开原图像素格式差异（预乘/通道顺序）
    private static func alphaBox(_ image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        var alpha = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = alpha.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var box = CGRect.null
        // 位图缓冲第 0 行即图像顶行（y 向下）
        for y in 0 ..< height {
            for x in 0 ..< width where alpha[y * width + x] > alphaThreshold {
                box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return box.isNull ? nil : box
    }
}
