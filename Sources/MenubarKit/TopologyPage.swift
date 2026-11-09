import Core
import SwiftUI

// TopologyPage.swift — 主窗口的拓扑页（某个屏幕排列：排列图 + 预设列表）。薄视图：只读 PresetManagerModel.state、只调 model 方法；
// 排序/高亮/可用性见 PresetManagerState，排列图几何见 DisplayArrangementLayout。
// ui-refactor 票 03：主窗口骨架落地时原样沿用 display-presets 票 07/08/13 的内容（标题行 | 排列图（点屏 = 详情筛选）| 预设列表）
// 作占位，只去掉左栏（侧栏归 MainWindowView）；spec §5.4 新拓扑页归票 04，整体替换本文件的 TopologyPage 即可
// （入口签名 TopologyPage(model:)，由 MainWindowView 在选中 .topology 时放进内容区）。

struct TopologyPage: View {
    @ObservedObject var model: PresetManagerModel

    var body: some View {
        VStack(spacing: 0) {
            if let selected = model.state.selected {
                TopologyHeader(selected: selected, onEditAlias: model.editAlias)
                DisplayArrangementView(displays: selected.displays,
                                       selectedUUID: model.state.selectedDisplayUUID,
                                       onSelect: model.selectDisplay)
                    .frame(minHeight: 180, idealHeight: 220)
                Divider()
                PresetList(model: model, selected: selected)
            } else {
                Text("还没有保存过任何预设")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, MainWindowMetrics.contentTop - 12)
    }
}

/// 右上标题行：拓扑名 + 改名称
private struct TopologyHeader: View {
    let selected: SelectedTopologyState
    let onEditAlias: () -> Void

    var body: some View {
        HStack {
            Text(selected.title).font(.headline)
            if !selected.isCurrent {
                Text("非当前屏幕排列，仅可查看与编辑").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("改名称…", action: onEditAlias).disabled(!selected.canEditAlias)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

/// 排列图：仿系统设置「显示器」，各屏按相对位置与比例绘制，标屏名与分辨率；点屏选中（再点取消）
private struct DisplayArrangementView: View {
    let displays: [TopologyDisplayInfo]
    let selectedUUID: String?
    let onSelect: (String?) -> Void

    var body: some View {
        GeometryReader { proxy in
            let arranged = DisplayArrangementLayout.layout(displays, in: proxy.size, padding: 16)
            ZStack(alignment: .topLeading) {
                ForEach(arranged) { display in
                    let isSelected = display.uuid == selectedUUID
                    // 相邻屏留 2pt 缝，贴合关系仍可辨
                    let rect = display.rect.insetBy(dx: 1, dy: 1)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.5),
                                    lineWidth: isSelected ? 2 : 1))
                        .overlay(
                            VStack(spacing: 2) {
                                Text(display.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                                Text(display.resolutionText).font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(4))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .onTapGesture { onSelect(display.uuid) }
                        .help(isSelected ? "再次点击显示全部屏幕" : "只看这块屏幕的详情")
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
    }
}

/// 右下：预设列表
private struct PresetList: View {
    @ObservedObject var model: PresetManagerModel
    let selected: SelectedTopologyState

    var body: some View {
        if selected.rows.isEmpty {
            Text(selected.isCurrent ? "当前屏幕排列还没有预设，可从菜单「保存当前布局为预设…」保存" : "无预设")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(selected.rows) { row in
                    PresetRowView(model: model, row: row)
                }
            }
        }
    }
}

private struct PresetRowView: View {
    @ObservedObject var model: PresetManagerModel
    let row: PresetRowState

    private var isExpanded: Bool { model.state.expandedPresetID == row.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { model.toggleExpanded(presetID: row.id) } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right").frame(width: 12)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(row.name).fontWeight(.medium)
                        if row.isLastRestored {
                            Text("最近恢复").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(row.savedAtText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("自动", isOn: Binding(get: { row.isAuto },
                                            set: { model.setAuto($0, presetID: row.id) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()
                    .help("屏幕排列变化后命中自动预设即直接恢复；每个屏幕排列至多一个")
                Button("恢复") { model.restore(presetID: row.id) }
                    .disabled(!row.canRestore)
                if row.showsOverwrite {
                    Button("覆盖…") { model.overwrite(presetID: row.id) }
                        .disabled(!row.canOverwrite)
                        .help("用当前布局覆盖此预设")
                }
                Menu {
                    Button("改名…") { model.rename(presetID: row.id) }
                    Divider()
                    Button("删除…", role: .destructive) { model.delete(presetID: row.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if isExpanded, let detail = model.expandedDetail {
                PresetDetailView(detail: detail)
                    .padding(.leading, 22)
            }
        }
        .padding(.vertical, 4)
    }
}
