import SwiftUI

// MainWindowView.swift — 统一主窗口根视图（ui-refactor 票 03，spec §5.1/§5.2）。薄视图：只读 MainWindowModel.state、
// 只调 model 方法（侧栏分组/选中/状态点推导在 MainWindowState）。
// 布局（Swish 式）：通高 150pt 实底侧栏（顶部让出与 header 同高的红绿灯带、分组行可滚动、底部固定「退出」）| 1pt 分隔线 | 内容区。
// 内容区顶部固定玻璃 header（票 10，MainWindowHeader），页面内容从其下方起排、上滚时从其下穿过；按选中页切换：拓扑页（TopologyPage，票 04 替换）/ 通用页（GeneralPage）/ 关于页（AboutPage）。

struct MainWindowView: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        HStack(spacing: 0) {
            MainSidebar(model: model)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .safeAreaInset(edge: .top, spacing: 0) { MainWindowHeader() }
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea()  // 全尺寸内容：侧栏通到窗口顶，红绿灯浮在侧栏上
        .frame(minWidth: MainWindowController.minimumSize.width, minHeight: MainWindowController.minimumSize.height)
    }

    @ViewBuilder private var content: some View {
        switch model.state.selection {
        case .topology:
            TopologyPage(model: model.presets)
        case .general:
            GeneralPage(model: model)
        case .about:
            AboutPage(model: model)
        }
    }
}

/// 侧栏：红绿灯带（与 header 同高，红绿灯由 TrafficLightPositioner 垂直居中其中）→ 分组（可滚动）→ 底部「退出」
private struct MainSidebar: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: MainWindowMetrics.headerHeight)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.state.sections) { section in
                        SidebarGroupLabel(text: section.title)
                        ForEach(section.rows) { row in
                            SidebarRowView(row: row, isSelected: row.page == model.state.selection) {
                                model.select(row.page)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SidebarQuitButton()
        }
        .padding(.horizontal, MainWindowMetrics.sidebarRowInset).padding(.bottom, 12)
        .frame(width: MainWindowMetrics.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SidebarBackground())
    }
}
