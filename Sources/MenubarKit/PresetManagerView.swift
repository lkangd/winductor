import Core
import SwiftUI

// PresetManagerView.swift — 预设管理窗口视图（display-presets spec §6.4，票 07）。薄视图：只读
// PresetManagerModel.state、只调 model 方法；排序/高亮/可用性见 PresetManagerState，排列图几何见 DisplayArrangementLayout。
// 布局：左栏拓扑列表 | 右上排列图（点屏 = 详情筛选，票 08）| 右下预设列表（每行：展开、名称/时间、自动开关、恢复、更多）。

struct PresetManagerView: View {
    @ObservedObject var model: PresetManagerModel

    var body: some View {
        HSplitView {
            TopologySidebar(model: model)
                .frame(minWidth: 200, idealWidth: 230, maxWidth: 320)
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
            .frame(minWidth: 480)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

/// 左栏：当前拓扑置顶高亮，其他灰显
private struct TopologySidebar: View {
    @ObservedObject var model: PresetManagerModel

    var body: some View {
        List(selection: Binding(get: { model.state.selectedKey },
                                set: { key in if let key { model.selectTopology(key) } })) {
            ForEach(model.state.entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(entry.title).fontWeight(entry.isCurrent ? .semibold : .regular)
                        if entry.isCurrent {
                            Text("当前").font(.caption2).padding(.horizontal, 4)
                                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        }
                    }
                    Text(entry.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                .foregroundStyle(entry.isCurrent ? .primary : .secondary)
                .padding(.vertical, 2)
                .tag(entry.key)
            }
        }
        .listStyle(.sidebar)
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
                    PresetRowView(model: model, selected: selected, row: row)
                }
            }
        }
    }
}

private struct PresetRowView: View {
    @ObservedObject var model: PresetManagerModel
    let selected: SelectedTopologyState
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
                    .help("拓扑变化后命中自动预设即直接恢复；每个屏幕排列至多一个")
                Button("恢复") { model.restore(presetID: row.id) }
                    .disabled(!row.canRestore)
                Menu {
                    Button("用当前布局覆盖…") { model.overwrite(presetID: row.id) }
                        .disabled(!row.canOverwrite)
                    Button("改名…") { model.rename(presetID: row.id) }
                    Divider()
                    Button("删除…", role: .destructive) { model.delete(presetID: row.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if isExpanded, let preset = model.selectedTopologyRecord?.presets.first(where: { $0.id == row.id }) {
                PresetDetailView(topology: selected, preset: preset,
                                 displayFilter: model.state.selectedDisplayUUID)
                    .padding(.leading, 22)
            }
        }
        .padding(.vertical, 4)
    }
}
