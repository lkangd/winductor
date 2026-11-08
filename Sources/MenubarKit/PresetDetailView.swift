import Core
import SwiftUI

// PresetDetailView.swift — 预设详情展开区（display-presets spec §6.4「预设详情」，票 08）。
// 薄视图：只渲染 PresetManagerModel.expandedDetail（推导见 Core/PresetDetail：屏 → Space → 应用，
// 「其中 N 个最小化」、「全屏 · 应用名」、随排列图点屏筛选、Space 不足提示仅当前拓扑）。

struct PresetDetailView: View {
    let detail: PresetDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(detail.spaceShortages, id: \.displayUUID) { shortage in
                Label(shortage.text, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(detail.displays, id: \.uuid) { display in
                VStack(alignment: .leading, spacing: 3) {
                    Label(display.name, systemImage: "display").font(.caption).fontWeight(.semibold)
                    ForEach(display.spaces, id: \.index) { space in
                        SpaceDetailRow(space: space).padding(.leading, 18)
                    }
                    if display.spaces.isEmpty {
                        Text("无 Space 记录").font(.caption).foregroundStyle(.secondary).padding(.leading, 18)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SpaceDetailRow: View {
    let space: PresetDetailSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(space.title).font(.caption).foregroundStyle(space.isFullscreen ? .primary : .secondary)
            ForEach(space.apps, id: \.bundleID) { app in
                Text(app.text).font(.caption).padding(.leading, 14)
            }
            if space.apps.isEmpty && !space.isFullscreen {
                Text("无窗口").font(.caption).foregroundStyle(.tertiary).padding(.leading, 14)
            }
        }
    }
}
