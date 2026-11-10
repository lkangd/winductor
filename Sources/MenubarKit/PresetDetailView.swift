import Core
import SwiftUI

// PresetDetailView.swift — 预设块展开详情（display-presets 票 08；ui-refactor 票 04 按 spec §5.4 改为等高卡片，数值取原型
// Prototypes/UIRefactor MainWindow.swift PresetBlock.detail）。薄视图：只渲染 PresetManagerModel.expandedDetail
// （推导与行内短文案见 Core/PresetDetail：屏 → Space → 应用，随排列图点屏筛选）。
//   每块屏一张卡片横排、等高；卡片头 = 屏图标（内置屏笔记本、其余显示器）+ 屏名；
//   内部按 Space 分组（「桌面 N」/「全屏」小标题），每个应用一行：真实应用图标 16pt + 名称 +「×N」（N>1）+「N 个最小化」；
//   无应用的用户桌面显示「空桌面」。Space 不足提示挂在预设块上（PresetRowState.spaceShortageTexts），不在此重复。

struct PresetDetailView: View {
    let detail: PresetDetail

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(detail.displays, id: \.uuid) { display in
                DisplayCard(display: display)
            }
        }
        .fixedSize(horizontal: false, vertical: true)  // 卡片等高：取最高一张
    }
}

private struct DisplayCard: View {
    let display: PresetDetailDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                Text(display.name).font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .help(display.name)
            }
            ForEach(display.spaces, id: \.index) { space in
                SpaceGroup(space: space)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.035)))
    }
}

private struct SpaceGroup: View {
    let space: PresetDetailSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(space.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ForEach(space.apps, id: \.bundleID) { app in
                AppLine(app: app)
            }
            if let emptyText = space.emptyText {
                Text(emptyText).font(.system(size: 12)).foregroundStyle(.tertiary).frame(height: 18)
            }
        }
    }
}

private struct AppLine: View {
    let app: PresetDetailApp

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: ApplicationIcons.icon(bundleID: app.bundleID))
                .resizable().interpolation(.high).frame(width: 16, height: 16)
            Text(app.name).font(.system(size: 12)).lineLimit(1)
            if let countText = app.windowCountText {
                Text(countText).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            if let minimizedText = app.minimizedText {
                Text(minimizedText).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(height: 18)
        .help(app.text)
    }
}
