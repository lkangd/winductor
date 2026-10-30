import AppKit

// WarningDotOverlay.swift — 未就绪警示点叠加（票 18，spec §8.1「未就绪：同图 + 黄色警示点」）。
// 与容器解耦（挂任意视图，生产用 NSStatusBarButton）：常态网格图保持模板色自适应
// （明暗模式自动反色），警示点为独立黄色小圆点子视图叠加右下角，非模板保持黄色。
// 恢复中第三态（临时换同步图形）归票 19。

enum WarningDotOverlay {
    /// 警示点子视图标识（测试与票 19 按此查找）
    static let identifier = NSUserInterfaceItemIdentifier("permission-warning-dot")

    /// 在容器右下角叠加警示点（幂等：已存在不重复添加）
    static func show(on container: NSView) {
        guard !container.subviews.contains(where: { $0.identifier == identifier }) else { return }
        let dot = NSView(frame: .zero)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemYellow.cgColor
        dot.layer?.cornerRadius = 3.5
        dot.identifier = identifier
        dot.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            dot.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: 2),
        ])
    }

    /// 移除警示点（幂等）
    static func hide(from container: NSView) {
        container.subviews
            .filter { $0.identifier == identifier }
            .forEach { $0.removeFromSuperview() }
    }
}
