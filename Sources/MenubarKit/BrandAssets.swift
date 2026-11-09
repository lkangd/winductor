import AppKit
import SwiftUI

// BrandAssets.swift — 品牌资源入口（UI 重构票 01，ui-refactor spec §3）。
// 素材在仓库 Resources/Brand/：菜单栏两态 128px 模板原图（黑 + 透明）、AppIcon.appiconset（白底无 alpha）。
// 不走 SwiftPM resources（Bundle.module 在自组装 .app 里要求资源包放 .app 根目录，签名不收；找不到还 fatalError），
// 改为两路显式查找：
//   - .app 内（Bundle.main 是 .app）：只读 Contents/Resources——make-app.sh 拷入两态 PNG、用 iconutil 生成 AppIcon.icns；
//     缺文件即返回 nil，不回落源码树，避免开发机上掩盖打包漏拷。
//   - 其余（swift test / swift run）：读源码树 Resources/Brand（#filePath 推导）。
// 票 02（菜单栏裁切/徽记）、05（关于页 36pt）、06（授权窗 64pt）从这里取图；本层不缓存，调用方按需缓存。

public enum BrandAssets {
    /// 菜单栏图形两态
    public enum MenuBarArt: CaseIterable {
        case idle
        case restoring
    }

    /// 应用图标圆角半径 / 边长（spec §3：连续圆角，半径 = 边长 × 0.225）
    public static let appIconCornerRatio: CGFloat = 0.225

    /// 菜单栏两态原图（128×128 px RGBA）。原样返回位图，供票 02 按 alpha 求主体框、裁切缩放成模板图
    public static func menuBarSource(_ art: MenuBarArt, bundle: Bundle = .main) -> NSBitmapImageRep? {
        let url = directory(for: bundle).appendingPathComponent(menuBarFileName(art))
        return NSImageRep(contentsOf: url) as? NSBitmapImageRep
    }

    /// 应用图标原图（多分辨率 16–1024 px，白底方图，未裁圆角）。.app 内读 AppIcon.icns，否则读 appiconset 各 PNG
    public static func appIconSource(bundle: Bundle = .main) -> NSImage? {
        let dir = directory(for: bundle)
        if isAppBundle(bundle) {
            return NSImage(contentsOf: dir.appendingPathComponent("AppIcon.icns"))
        }
        return imageFromAppIconSet(dir.appendingPathComponent("AppIcon.appiconset"))
    }

    /// 界面用应用图标：边长 side（pt）的方图，裁连续圆角，不描边。按绘制分辨率惰性重绘，1x/2x 均取合适原图分辨率
    public static func appIcon(side: CGFloat, bundle: Bundle = .main) -> NSImage? {
        guard let source = appIconSource(bundle: bundle) else { return nil }
        let radius = side * appIconCornerRatio
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            ctx.addPath(RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath)
            ctx.clip()
            source.draw(in: rect)
            ctx.restoreGState()
            return true
        }
    }

    // MARK: - 资源位置

    /// 仓库内素材目录（Sources/MenubarKit/ → 仓库根 → Resources/Brand）
    static let sourceTreeDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/Brand", isDirectory: true)

    static func menuBarFileName(_ art: MenuBarArt) -> String {
        switch art {
        case .idle: "MenuBarIdle_128px.png"
        case .restoring: "MenuBarRestoring_128px.png"
        }
    }

    private static func isAppBundle(_ bundle: Bundle) -> Bool {
        bundle.bundleURL.pathExtension == "app"
    }

    private static func directory(for bundle: Bundle) -> URL {
        if isAppBundle(bundle) {
            return bundle.resourceURL ?? bundle.bundleURL.appendingPathComponent("Contents/Resources")
        }
        return sourceTreeDirectory
    }

    /// appiconset → 多分辨率 NSImage：文件名 icon_{N}x{N}[@2x].png，每张的逻辑尺寸取 N pt（与 icns 同构），
    /// 绘制时由 AppKit 按目标像素挑最合适的一张
    private static func imageFromAppIconSet(_ dir: URL) -> NSImage? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let image = NSImage()
        var maxPoints: CGFloat = 0
        for file in files.sorted() {
            guard let match = file.wholeMatch(of: #/icon_(\d+)x\d+(@2x)?\.png/#),
                  let points = Double(match.1),
                  let rep = NSImageRep(contentsOf: dir.appendingPathComponent(file)) else { continue }
            rep.size = NSSize(width: points, height: points)
            image.addRepresentation(rep)
            maxPoints = max(maxPoints, points)
        }
        guard maxPoints > 0 else { return nil }
        image.size = NSSize(width: maxPoints, height: maxPoints)
        return image
    }
}
