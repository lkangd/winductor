import AppKit
import SwiftUI

// MainWindowStyle.swift — 统一主窗口的版式常量与共享小件（ui-refactor 票 03，spec §5.2/§5.3；数值取原型
// Prototypes/UIRefactor Style.swift）。拓扑页（票 04）与授权窗（票 05/06）复用同一视觉语言：
//   内容区左右内边距 32、顶部 40；分区标题 22 bold；字段标签 13 semibold；说明 12 次要色；分区间 Divider 上下各 20；
//   设置行 = 粗体标签 + 行内控件同一行（间距 24），说明在下一行；内容区按钮统一 .bordered、同一 controlSize。

enum MainWindowMetrics {
    static let contentInset: CGFloat = 32
    static let contentTop: CGFloat = 40
    static let sidebarWidth: CGFloat = 150
    static let sidebarRowHeight: CGFloat = 36
}

// MARK: - 环境

private struct DrawsTrafficLightPlaceholderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 窗口是否为前台 key 窗口（失焦时侧栏图标与文字转次要灰）
    var isMainWindowKey: Bool { controlActiveState == .key || controlActiveState == .active }

    /// 离屏渲染时在侧栏顶部画红绿灯占位（实况由真窗口提供；只供渲染 harness 打开）
    var drawsTrafficLightPlaceholder: Bool {
        get { self[DrawsTrafficLightPlaceholderKey.self] }
        set { self[DrawsTrafficLightPlaceholderKey.self] = newValue }
    }
}

// MARK: - 内容区版式

/// 页面滚动骨架：左右 32、顶部 40、底部 32，内容左对齐
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, MainWindowMetrics.contentInset)
                .padding(.top, MainWindowMetrics.contentTop)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 分区标题 22pt bold
struct SectionTitle: View {
    let text: String

    var body: some View { Text(text).font(.system(size: 22, weight: .bold)) }
}

/// 分区标题行：标题 + 可选行尾控件（垂直居中）
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center) {
            SectionTitle(text: title)
            Spacer()
            trailing()
        }
        .padding(.bottom, 8)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// 分区间分隔线（上下各 20）
struct SectionDivider: View {
    var body: some View { Divider().padding(.vertical, 20) }
}

/// 字段标签 13pt semibold
struct FieldLabel: View {
    let text: String

    var body: some View { Text(text).font(.system(size: 13, weight: .semibold)) }
}

/// 说明 12pt 次要色，可折行
struct Caption: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Swish 式设置行：控件同一行（间距 24），说明在下一行
struct SettingRow<Controls: View>: View {
    let caption: String
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 24) { controls() }.frame(minHeight: 22)
            Caption(text: caption)
        }
        .padding(.vertical, 8)
    }
}

/// 状态圆点（7pt）
struct StatusDot: View {
    let color: Color

    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

/// 内容区按钮统一外观（.bordered + 同一 controlSize）
extension View {
    func contentButtonStyle() -> some View {
        buttonStyle(.bordered).controlSize(.regular)
    }
}

// MARK: - 侧栏

/// 侧栏实底：浅色 #ecedee，深色 #2b2b2e
struct SidebarBackground: View {
    static let color = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x2B / 255.0, green: 0x2B / 255.0, blue: 0x2E / 255.0, alpha: 1)
            : NSColor(srgbRed: 0xEC / 255.0, green: 0xED / 255.0, blue: 0xEE / 255.0, alpha: 1)
    }

    var body: some View { Color(nsColor: Self.color) }
}

/// 红绿灯位置占位（52×12）：实况由真窗口在此处画红绿灯；离屏渲染时画三色圆点近似
struct TrafficLightSpace: View {
    @Environment(\.drawsTrafficLightPlaceholder) private var drawsPlaceholder

    var body: some View {
        HStack(spacing: 8) {
            if drawsPlaceholder {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
            }
        }
        .frame(width: 52, height: 12, alignment: .leading)
    }
}

/// 侧栏组名（11pt semibold 次要色）
struct SidebarGroupLabel: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 2)
    }
}

/// 侧栏行：单色图标（resizable 进 16×16 框）+ 13pt 文字，行高 36、左右 10、圆角 8；
/// 前台：图标强调色，选中行强调色底 + 白色 semibold 字；失焦：图标与文字转次要灰，选中行 primary 7% 底 + semibold 字
struct SidebarRowView: View {
    let row: SidebarRow
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.isMainWindowKey) private var isKey

    var body: some View {
        let onAccent = isSelected && isKey
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: row.symbolName).resizable().scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(onAccent ? Color.white : isKey ? Color.accentColor : Color.secondary)
                Text(row.title).font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(onAccent ? Color.white : isKey ? Color.primary : Color.secondary)
                Spacer(minLength: 2)
                if row.showsStatusDot { StatusDot(color: .yellow) }
            }
            .padding(.horizontal, 10)
            .frame(height: MainWindowMetrics.sidebarRowHeight)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(!isSelected ? Color.clear : isKey ? Color.accentColor : Color.primary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.title)
    }
}

/// 侧栏底部「退出」：常态次要色，悬停时图标与文字变红；点击退出应用
struct SidebarQuitButton: View {
    @State private var isHovering = false

    var body: some View {
        Button { NSApplication.shared.terminate(nil) } label: {
            HStack(spacing: 8) {
                Image(systemName: "power").resizable().scaledToFit().frame(width: 14, height: 14)
                Text("退出").font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .foregroundStyle(isHovering ? Color.red : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("退出 Winductor")
    }
}
