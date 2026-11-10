import AppKit
import CoreText
import SwiftUI

/// 页头按可见内容而不是透明画布/字体行框对齐：图标使用 alpha 重心，文字使用首末行字形的可见边缘。
enum PermissionHeaderAlignment {
    private enum VisualCenter: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat { dimensions[VerticalAlignment.center] }
    }

    static let vertical = VerticalAlignment(VisualCenter.self)

    static func iconCenter(_ image: NSImage, side: CGFloat) -> CGFloat {
        let height = min(side, side * image.size.height / image.size.width)
        return (side - height) / 2 + height * alphaCentroidY(image)
    }

    /// 图片行坐标自上而下；位图直接求和，避免逐像素构造 NSColor。全透明或未知格式回落几何中心。
    static func alphaCentroidY(_ image: NSImage) -> CGFloat {
        guard let rep = image.representations.first as? NSBitmapImageRep,
              rep.hasAlpha, !rep.isPlanar, rep.bitsPerSample == 8,
              let data = rep.bitmapData else { return 0.5 }
        let alpha = rep.bitmapFormat.contains(.alphaFirst) ? 0 : rep.samplesPerPixel - 1
        var total: Double = 0, weighted: Double = 0
        for y in 0..<rep.pixelsHigh {
            var row: Double = 0
            for x in 0..<rep.pixelsWide {
                row += Double(data[y * rep.bytesPerRow + x * rep.samplesPerPixel + alpha])
            }
            total += row
            weighted += row * (Double(y) + 0.5)
        }
        return total > 0 ? CGFloat(weighted / total / Double(rep.pixelsHigh)) : 0.5
    }

    /// SwiftUI baseline 向下为正，Core Text 字形边界的 y 轴向上；支持说明折行后的末行基线。
    static func textCenter(firstBaseline: CGFloat, lastBaseline: CGFloat, title: String, subtitle: String) -> CGFloat {
        let top = firstBaseline - inkBounds(title, font: .systemFont(ofSize: 20, weight: .bold)).maxY
        let bottom = lastBaseline - inkBounds(subtitle, font: .systemFont(ofSize: 12)).minY
        return (top + bottom) / 2
    }

    private static func inkBounds(_ text: String, font: NSFont) -> CGRect {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CTLineGetImageBounds(line, nil)
    }
}
