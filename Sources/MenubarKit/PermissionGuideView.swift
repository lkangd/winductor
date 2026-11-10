import AppKit
import SwiftUI

// PermissionGuideView.swift — 授权窗 SwiftUI 视图（ui-refactor 票 05，spec §6；视觉以原型 PermissionWindow.swift 为准）。
// 薄视图：只读 PermissionGuideModel.state、按钮只回调 model 动作；状态推导见 PermissionGuideState。
// 对齐：页头、分组框、底部状态条共用同一左缘；行内边距 14，状态条图标列与行图标列（28pt）对齐；
// 行间分隔线从文字列起（14 + 28 + 12）。
// 上下留白（票 09）：内容铺进透明标题栏（宿主不传安全区，见 PermissionGuideWindow.install——否则 SwiftUI 会再让出
// 整条标题栏高度），页头上方与底部状态条下方同为 edgeSpace；edgeSpace 须让页头避开红绿灯（macOS 27 红绿灯下缘距窗顶 23pt）。

/// 授权窗视图模型：PermissionGuideWindow 每次 update(status:) 换新状态；视图按钮经 press* 回传
///（按钮不可见时入口不响应，测试与视图同走这一处）
final class PermissionGuideModel: ObservableObject {
    @Published var state: PermissionGuideState
    private let openSettings: (PermissionMonitor.Kind) -> Void
    private let relaunch: () -> Void

    init(state: PermissionGuideState, openSettings: @escaping (PermissionMonitor.Kind) -> Void,
         relaunch: @escaping () -> Void) {
        self.state = state
        self.openSettings = openSettings
        self.relaunch = relaunch
    }

    /// 行尾【打开系统设置】
    func pressOpenSettings(_ kind: PermissionMonitor.Kind) {
        guard state.rows.contains(where: { $0.kind == kind && $0.showsOpenSettingsButton }) else { return }
        openSettings(kind)
    }

    /// 底部【立即重启】
    func pressRestart() {
        guard state.footer.showsRestartButton else { return }
        relaunch()
    }
}

enum PermissionGuideMetrics {
    static let width: CGFloat = 580
    static let inset: CGFloat = 24
    static let rowInset: CGFloat = 14
    static let iconTile: CGFloat = 28
    static let iconTileRadius: CGFloat = 7
    static let columnSpacing: CGFloat = 12
    static let trailingColumn: CGFloat = 116
    static let headerIcon: CGFloat = 64
    static let groupRadius: CGFloat = 10
    /// 窗顶到页头、底部状态条到窗底的留白（相等，视觉平衡；= macOS 27 透明标题栏高度，页头恰在红绿灯区之下）
    static let edgeSpace: CGFloat = 32
}

struct PermissionGuideView: View {
    @ObservedObject var model: PermissionGuideModel

    /// 页头只用透明主体，不加底板、边框或裁圆角；资源缺失时去掉图标。
    static let headerIcon = BrandAssets.appIconSubject()
    private static let headerIconCenter = headerIcon.map {
        PermissionHeaderAlignment.iconCenter($0, side: PermissionGuideMetrics.headerIcon)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            list.padding(.top, 20)
            footer.padding(.top, 16)
        }
        .padding(.horizontal, PermissionGuideMetrics.inset)
        .padding(.vertical, PermissionGuideMetrics.edgeSpace)
        .frame(width: PermissionGuideMetrics.width)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: PermissionHeaderAlignment.vertical, spacing: 14) {
            if let icon = Self.headerIcon {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
                    .frame(width: PermissionGuideMetrics.headerIcon, height: PermissionGuideMetrics.headerIcon)
                    .alignmentGuide(PermissionHeaderAlignment.vertical) { dimensions in
                        Self.headerIconCenter ?? dimensions[VerticalAlignment.center]
                    }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.state.title).font(.system(size: 20, weight: .bold))
                GuideCaption(text: model.state.subtitle)
            }
            .alignmentGuide(PermissionHeaderAlignment.vertical) { dimensions in
                PermissionHeaderAlignment.textCenter(
                    firstBaseline: dimensions[.firstTextBaseline], lastBaseline: dimensions[.lastTextBaseline],
                    title: model.state.title, subtitle: model.state.subtitle)
            }
        }
    }

    private var list: some View {
        let shape = RoundedRectangle(cornerRadius: PermissionGuideMetrics.groupRadius, style: .continuous)
        return VStack(spacing: 0) {
            ForEach(Array(model.state.rows.enumerated()), id: \.element.kind) { index, row in
                if index > 0 {
                    Divider().padding(.leading, PermissionGuideMetrics.rowInset + PermissionGuideMetrics.iconTile
                        + PermissionGuideMetrics.columnSpacing)
                }
                PermissionGuideRowView(row: row) { model.pressOpenSettings(row.kind) }
            }
        }
        .background(shape.fill(Color.primary.opacity(0.035)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.07)))
    }

    private var footer: some View {
        let footer = model.state.footer
        return HStack(alignment: .center, spacing: PermissionGuideMetrics.columnSpacing) {
            Group {
                if footer.isReady {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(.green)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: PermissionGuideMetrics.iconTile)
            VStack(alignment: .leading, spacing: 2) {
                if let title = footer.title {
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                GuideCaption(text: footer.caption)
            }
            Spacer(minLength: PermissionGuideMetrics.columnSpacing)
            if footer.showsRestartButton {
                Button(footer.restartButtonTitle) { model.pressRestart() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, PermissionGuideMetrics.rowInset)
    }
}

/// 分组列表一行：彩色图标块 + 名称/说明/路径 + 固定宽行尾列（按钮或「✓ 已授权」）
private struct PermissionGuideRowView: View {
    let row: PermissionGuideState.Row
    let onOpenSettings: () -> Void

    private var tint: Color {
        switch row.kind {
        case .accessibility: .blue
        case .screenCapture: .red
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: PermissionGuideMetrics.columnSpacing) {
            RoundedRectangle(cornerRadius: PermissionGuideMetrics.iconTileRadius, style: .continuous)
                .fill(tint.gradient)
                .frame(width: PermissionGuideMetrics.iconTile, height: PermissionGuideMetrics.iconTile)
                .overlay(Image(systemName: row.symbolName).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).font(.system(size: 13, weight: .semibold))
                GuideCaption(text: row.detail)
                if let path = row.settingsPath {
                    Text(path).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: PermissionGuideMetrics.columnSpacing)
            Group {
                if row.showsOpenSettingsButton {
                    Button(PermissionGuideState.Row.openSettingsButtonTitle, action: onOpenSettings)
                } else {
                    Label(row.grantedText, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
                }
            }
            .frame(width: PermissionGuideMetrics.trailingColumn, alignment: .trailing)
        }
        .padding(.horizontal, PermissionGuideMetrics.rowInset)
        .padding(.vertical, 12)
    }
}

/// 说明文字：12pt 次要色，可换行
private struct GuideCaption: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
