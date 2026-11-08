import Core
import CoreGraphics

// DisplayArrangementLayout.swift — 预设管理窗口排列图的布局计算（display-presets spec §6.4 右上，票 07）。
// 仿系统设置「显示器」：按拓扑展示数据（§3.2，最近一次见到的全局 point frame）的相对位置与比例绘制各屏——
// 全部屏的包围盒等比缩放进画布（减四周内边距）并居中；竖屏照实（frame 本身已是旋转后的宽高）。
// 画布坐标左上原点、y 向下，与 CGDisplayBounds 全局坐标同向，无需翻转。纯函数，视图只负责画矩形与标注。

/// 排列图中的一块屏（画布坐标）
public struct ArrangedDisplay: Equatable, Identifiable {
    public var id: String { uuid }
    public let uuid: String
    public let name: String
    /// 分辨率标注（像素，「宽×高」）
    public let resolutionText: String
    /// 缩放后的视图矩形
    public let rect: CGRect
    /// 竖屏（高 > 宽）
    public var isPortrait: Bool { rect.height > rect.width }
}

public enum DisplayArrangementLayout {
    /// 展示数据 → 画布内矩形（顺序同输入）。无屏、包围盒退化或画布不足内边距时返回空。
    public static func layout(_ displays: [TopologyDisplayInfo], in canvas: CGSize,
                              padding: CGFloat = 12) -> [ArrangedDisplay] {
        let frames = displays.map { CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.w, height: $0.frame.h) }
        guard let first = frames.first else { return [] }
        let bounds = frames.dropFirst().reduce(first) { $0.union($1) }
        let available = CGSize(width: canvas.width - padding * 2, height: canvas.height - padding * 2)
        guard bounds.width > 0, bounds.height > 0, available.width > 0, available.height > 0 else { return [] }

        let scale = min(available.width / bounds.width, available.height / bounds.height)
        // 内容居中：可用区剩余空间两侧平分
        let origin = CGPoint(x: padding + (available.width - bounds.width * scale) / 2,
                             y: padding + (available.height - bounds.height * scale) / 2)
        return zip(displays, frames).map { info, frame in
            ArrangedDisplay(
                uuid: info.uuid,
                name: info.name,
                resolutionText: "\(info.pixelWidth)×\(info.pixelHeight)",
                rect: CGRect(x: origin.x + (frame.minX - bounds.minX) * scale,
                             y: origin.y + (frame.minY - bounds.minY) * scale,
                             width: frame.width * scale,
                             height: frame.height * scale))
        }
    }
}
