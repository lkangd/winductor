import Core
import SwiftUI

// PresetDetailView.swift — 预设详情展开区（display-presets spec §6.4「预设详情」）。
// 票 07 只留插槽：预设行展开时在此渲染，入参已备齐——
//   topology：选中拓扑（isCurrent 决定是否显示 Space 不足提示，displays 供屏名）；
//   preset：完整预设（含快照，取自 PresetManagerModel.selectedTopologyRecord）；
//   displayFilter：排列图点选的屏 UUID（nil = 全部屏，非 nil 只显示该屏）。
// 票 08 在此实现「屏幕 → Space → 应用（窗口数，其中 N 个最小化）」/「全屏 · 应用名」/ Space 不足提示。

struct PresetDetailView: View {
    let topology: SelectedTopologyState
    let preset: Preset
    let displayFilter: String?

    var body: some View {
        // 票 08 前的占位：只给出窗口总数
        Text("共 \(preset.snapshot.windows.count) 个窗口（详情待补）")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
