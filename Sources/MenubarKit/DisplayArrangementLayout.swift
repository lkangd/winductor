import Core
import CoreGraphics

// DisplayArrangementLayout.swift — 拓扑页排列图的布局计算（display-presets 票 07；ui-refactor 票 04 spec §5.4 沿用）。
// 仿系统设置「显示器」：按拓扑展示数据（§3.2，最近一次见到的全局 point frame）的相对位置与比例绘制各屏——
// 全部屏的包围盒等比缩放进画布（减四周内边距）并居中；竖屏照实（frame 本身已是旋转后的宽高）。
// 画布坐标左上原点、y 向下，与 CGDisplayBounds 全局坐标同向，无需翻转。纯函数，视图只负责画矩形与标注。
// 标注：屏名（同名加「#n」，同详情卡片）+ 像素分辨率「宽 × 高」+ 是否内置屏（刘海）。

/// 排列图中的一块屏（画布坐标）
public struct ArrangedDisplay: Equatable, Identifiable {
    public var id: String { uuid }
    public let uuid: String
    public let name: String
    /// 分辨率标注（像素，「宽 × 高」）
    public let resolutionText: String
    /// 内置屏（顶部居中画刘海；展示数据缺省 = 旧数据，按非内置，ui-refactor 票 04）
    public let isBuiltin: Bool
    /// 缩放后的视图矩形
    public let rect: CGRect
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
        // 同名屏按自左而右加「#n」，与预设详情卡片（TopologyNaming.orderedDisplays）同名（ui-refactor 票 04）
        let leftToRight = displays.sorted { ($0.frame.x, $0.frame.y) < ($1.frame.x, $1.frame.y) }
        let names = Dictionary(zip(leftToRight.map(\.uuid), TopologyNaming.disambiguated(leftToRight.map(\.name))),
                               uniquingKeysWith: { first, _ in first })
        return zip(displays, frames).map { info, frame in
            ArrangedDisplay(
                uuid: info.uuid,
                name: names[info.uuid] ?? info.name,
                resolutionText: "\(info.pixelWidth) × \(info.pixelHeight)",
                isBuiltin: info.isBuiltin ?? false,
                rect: CGRect(x: origin.x + (frame.minX - bounds.minX) * scale,
                             y: origin.y + (frame.minY - bounds.minY) * scale,
                             width: frame.width * scale,
                             height: frame.height * scale))
        }
    }
}
