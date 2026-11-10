import AppKit
import Core
import SwiftUI

// TopologyPage.swift — 主窗口的拓扑页（ui-refactor 票 04，spec §5.4；数值取原型 Prototypes/UIRefactor MainWindow.swift /
// Style.swift 的 TopologyPage、ArrangementDiagram、ScreenTile、PresetBlock、MoreButton）。
// 薄视图：只读 PresetManagerModel.state / expandedDetails、只调 model 方法；说明文案、可用性、摘要、`⋯` 菜单项见
// PresetManagerState，排列图几何见 DisplayArrangementLayout，详情卡片见 PresetDetailView。自上而下：
//   标题区：拓扑名（别名优先，22pt bold）+ 笔形改名按钮（别名对话框）；说明（当前 / 未连接）
//   排列图：高 150 的极淡容器；屏幕块 = 控件底色面板 + 1pt 次要描边 + 顶部 6pt 菜单栏条（内置屏居中刘海），不用渐变；
//     块高 < 70 只显示屏名（最多两行）；非当前拓扑整体 60% 不透明；点屏 = 详情只看该屏（强调色描边），再点取消
//   预设：标题 +「保存当前布局…」（仅当前拓扑）；预设块（块间 Divider）；末尾「自动恢复」说明

struct TopologyPage: View {
    @ObservedObject var model: PresetManagerModel

    var body: some View {
        if let selected = model.state.selected {
            PageScroll {
                TopologyTitle(selected: selected, onEditAlias: model.editAlias)
                ArrangementDiagram(state: model.state, displays: selected.displays, isDimmed: !selected.isCurrent,
                                   onSelect: model.selectDisplay)
                    .padding(.top, 16)
                SectionDivider()
                SectionHeader(title: "预设") {
                    if selected.showsSavePreset {
                        Button("保存当前布局…", action: model.savePreset)
                            .contentButtonStyle()
                            .disabled(!selected.canSavePreset)
                    }
                }
                if let emptyText = selected.emptyPresetsText {
                    Caption(text: emptyText).padding(.vertical, 14)
                }
                ForEach(Array(selected.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    PresetBlock(model: model, row: row)
                }
                Divider()
                Caption(text: SelectedTopologyState.autoRestoreNote).padding(.top, 12)
            }
        } else {
            Caption(text: PresetManagerState.noTopologyText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) { MainWindowHeader() }
        }
    }
}

// MARK: - 标题区

private struct TopologyTitle: View {
    let selected: SelectedTopologyState
    let onEditAlias: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                SectionTitle(text: selected.title)
                Button(action: onEditAlias) {
                    Image(systemName: "pencil").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(!selected.canEditAlias)
                .help(selected.editAliasHelp)
            }
            Caption(text: selected.subtitle)
        }
    }
}

// MARK: - 排列图

struct ArrangementDiagram: View {
    /// 点选的屏与悬停说明（PresetManagerState.selectedDisplayUUID / displayTileHelp）
    let state: PresetManagerState
    let displays: [TopologyDisplayInfo]
    let isDimmed: Bool
    let onSelect: (String?) -> Void

    /// 相邻屏之间留的缝（每块各内缩一半）
    private let gap: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let arranged = DisplayArrangementLayout.layout(displays, in: proxy.size, padding: 16)
            ZStack(alignment: .topLeading) {
                ForEach(arranged) { display in
                    let rect = display.rect.insetBy(dx: gap / 2, dy: gap / 2)
                    let isSelected = display.uuid == state.selectedDisplayUUID
                    Button { onSelect(display.uuid) } label: {
                        ScreenTile(display: display, isCompact: rect.height < 70, isSelected: isSelected,
                                   isDimmed: isDimmed)
                            .frame(width: rect.width, height: rect.height)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(display.name)
                    .accessibilityIdentifier(display.uuid)
                    .help(state.displayTileHelp(uuid: display.uuid))
                    // position 会把外层布局框扩到整幅画布：交互区域必须先限定在屏幕块内。
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .frame(height: 150)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// 屏幕块：控件底色面板 + 1pt 次要描边（选中 = 2pt 强调色）+ 顶部 6pt 菜单栏条；内置屏顶部居中刘海；不用渐变
private struct ScreenTile: View {
    let display: ArrangedDisplay
    let isCompact: Bool
    let isSelected: Bool
    let isDimmed: Bool

    private let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

    var body: some View {
        ZStack(alignment: .top) {
            shape.fill(Color(nsColor: .controlBackgroundColor))
            Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 6)
            if display.isBuiltin {
                UnevenRoundedRectangle(bottomLeadingRadius: 2.5, bottomTrailingRadius: 2.5)
                    .fill(Color.primary.opacity(0.55)).frame(width: 18, height: 4)
            }
            VStack(spacing: 2) {
                Text(display.name).font(.system(size: isCompact ? 10 : 11, weight: .medium))
                    .lineLimit(isCompact ? 2 : 1).multilineTextAlignment(.center)
                if !isCompact {
                    Text(display.resolutionText).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6).padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.2),
                                    lineWidth: isSelected ? 2 : 1))
        .shadow(color: .black.opacity(0.07), radius: 3, y: 1)
        .opacity(isDimmed ? 0.6 : 1)
    }
}

// MARK: - 预设块

private struct PresetBlock: View {
    @ObservedObject var model: PresetManagerModel
    let row: PresetRowState

    private var isExpanded: Bool { model.state.isDetailExpanded(presetID: row.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        FieldLabel(text: row.name)
                        if row.isLastRestored { CapsuleTag(text: "最近恢复") }
                    }
                    Caption(text: row.summaryText)
                }
                Spacer(minLength: 16)
                HStack(spacing: 6) {
                    Text("自动恢复").font(.system(size: 12))
                    Toggle("自动恢复", isOn: Binding(get: { row.isAuto },
                                                 set: { model.setAuto($0, presetID: row.id) }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
                .help("屏幕排列切换到这里时直接恢复；每个屏幕排列至多一个")
                HStack(spacing: 8) {
                    Button("恢复") { model.restore(presetID: row.id) }
                        .contentButtonStyle()
                        .disabled(!row.canRestore)
                    MoreMenuButton(items: row.menuItems) { model.perform($0, presetID: row.id) }
                }
            }
            ForEach(row.spaceShortageTexts, id: \.self) { text in
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            Button { model.toggleExpanded(presetID: row.id) } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(model.state.detailToggleTitle(presetID: row.id))
                }
                .font(.system(size: 12)).foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded, let detail = model.detail(presetID: row.id) {
                PresetDetailView(detail: detail).padding(.top, 4)
            }
        }
        .padding(.vertical, 14)
    }
}

/// 胶囊标签（「最近恢复」）：10pt semibold 次要色，12% 同色底
private struct CapsuleTag: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .foregroundStyle(.secondary)
    }
}

/// `⋯` 按钮：与相邻「恢复」同为 .bordered、等高；点击在指针处弹原生 NSMenu（项与可用性取自 PresetRowState.menuItems）
private struct MoreMenuButton: View {
    let items: [PresetRowMenuItem]
    let onSelect: (PresetRowAction) -> Void

    var body: some View {
        Button(action: popUp) {
            Image(systemName: "ellipsis").frame(width: 16, height: 16)
        }
        .contentButtonStyle()
        .help("更多")
    }

    private func popUp() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case let .action(action, title, isEnabled):
                let carrier = ActionCarrier { onSelect(action) }
                let menuItem = NSMenuItem(title: title, action: #selector(ActionCarrier.fire), keyEquivalent: "")
                menuItem.target = carrier
                menuItem.representedObject = carrier  // NSMenuItem.target 是弱引用：挂在 representedObject 上保活
                menuItem.isEnabled = isEnabled
                menu.addItem(menuItem)
            }
        }
        guard let event = NSApp.currentEvent, let view = event.window?.contentView else { return }
        menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
    }
}
