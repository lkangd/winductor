import AppKit
import SwiftUI

// BrandAssets.swift — 品牌资源入口（UI 重构票 01，ui-refactor spec §3；票 08 换透明底主体）。
// 素材在仓库 Resources/Brand/：菜单栏两态 128px 模板原图（黑 + 透明）、透明底主体 AppIconSubject.png
// （由用户白底原图抠出、按 alpha 外接框裁切，见 Scripts/brand-subject.swift）、Icon Composer 图标 AppIcon.icon（仅 make-app.sh 编译用）。
// 不走 SwiftPM resources（Bundle.module 在自组装 .app 里要求资源包放 .app 根目录，签名不收；找不到还 fatalError），
// 改为两路显式查找：
//   - .app 内（Bundle.main 是 .app）：只读 Contents/Resources——make-app.sh 拷入两态 PNG 与 AppIconSubject.png；
//     缺文件即返回 nil，不回落源码树，避免开发机上掩盖打包漏拷。
//   - 其余（swift test / swift run）：读源码树 Resources/Brand（RuntimeBundle.sourceTreeRoot 推导）。
// 票 02（菜单栏裁切/徽记）、关于页（透明主体，与标题 W 等高）、授权窗页头（64pt 白底圆角块）从这里取图。

public enum BrandAssets {
    /// 菜单栏图形两态
    public enum MenuBarArt: CaseIterable {
        case idle
        case restoring
    }

    /// 应用图标圆角半径 / 边长（spec §3：连续圆角，半径 = 边长 × 0.225）
    public static let appIconCornerRatio: CGFloat = 0.225

    /// 白底圆角块里主体的位置（单位 = 边长比例，y 自上而下）：与已批准的 1024 白底图标同构图
    /// （主体外接框 x 92…919、y 142…826 / 1024）
    static let appIconSubjectFrame = CGRect(x: 92.0 / 1024, y: 142.0 / 1024, width: 828.0 / 1024, height: 685.0 / 1024)

    /// 菜单栏两态原图（128×128 px RGBA）。原样返回位图，供票 02 按 alpha 求主体框、裁切缩放成模板图
    public static func menuBarSource(_ art: MenuBarArt, bundle: Bundle = .main) -> NSBitmapImageRep? {
        let url = directory(for: bundle).appendingPathComponent(menuBarFileName(art))
        return NSImageRep(contentsOf: url) as? NSBitmapImageRep
    }

    /// 透明底主体（指挥家 + 三窗，无白底、无投影），已按 alpha 外接框裁切——可见主体即整张图。
    /// 逻辑尺寸 = 像素尺寸（841×696），调用方按需缩放（保持宽高比）。按资源目录缓存，同一目录只解码一次
    public static func appIconSubject(bundle: Bundle = .main) -> NSImage? {
        let url = directory(for: bundle).appendingPathComponent(appIconSubjectFileName)
        return subjectCache.image(for: url)
    }

    /// 界面用应用图标：边长 side（pt）的白底方块，裁连续圆角、不描边，透明主体按已批准图标的构图画在块内。
    /// 按绘制分辨率惰性重绘
    public static func appIcon(side: CGFloat, bundle: Bundle = .main) -> NSImage? {
        guard let subject = appIconSubject(bundle: bundle) else { return nil }
        let radius = side * appIconCornerRatio
        let frame = appIconSubjectFrame
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            ctx.addPath(RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath)
            ctx.clip()
            ctx.setFillColor(.white)
            ctx.fill(rect)
            subject.draw(in: NSRect(x: rect.minX + frame.minX * rect.width,
                                    y: rect.minY + (1 - frame.maxY) * rect.height,
                                    width: frame.width * rect.width, height: frame.height * rect.height))
            ctx.restoreGState()
            return true
        }
    }

    // MARK: - 资源位置

    /// 仓库内素材目录（仓库根 → Resources/Brand）
    static let sourceTreeDirectory = RuntimeBundle.sourceTreeRoot
        .appendingPathComponent("Resources/Brand", isDirectory: true)

    static let appIconSubjectFileName = "AppIconSubject.png"

    static func menuBarFileName(_ art: MenuBarArt) -> String {
        switch art {
        case .idle: "MenuBarIdle_128px.png"
        case .restoring: "MenuBarRestoring_128px.png"
        }
    }

    private static func directory(for bundle: Bundle) -> URL {
        if RuntimeBundle.isApp(bundle) {
            return bundle.resourceURL ?? bundle.bundleURL.appendingPathComponent("Contents/Resources")
        }
        return sourceTreeDirectory
    }
}

/// 透明主体的解码缓存（按文件 URL；未命中的 nil 不缓存，便于资源补齐后重试）
private final class BrandImageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [URL: NSImage] = [:]

    func image(for url: URL) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = images[url] { return cached }
        guard let rep = NSImageRep(contentsOf: url) else { return nil }
        rep.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        images[url] = image
        return image
    }
}

private extension BrandAssets {
    static let subjectCache = BrandImageCache()
}
