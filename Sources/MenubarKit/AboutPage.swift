import SwiftUI

// AboutPage.swift — 主窗口「关于」页（ui-refactor 票 03，spec §5.6，参照 Swish About，不要授权行）。
//   「Winductor」34pt heavy + 应用图标 36pt（同行）；
//   三行（13pt，前置 13pt 次要色图标）：c.circle 作者 / globe 仓库链接（点开浏览器）/ rectangle.3.group 本机数据统计；
//   分隔线；「版本 {VERSION}」+「发行说明 ›」（打开 GitHub Releases）。无第三方依赖 → 不设开源库一节。

enum AboutLinks {
    static let repositoryText = "github.com/lkangd/winductor"
    static let repository = URL(string: "https://github.com/lkangd/winductor")!
    static let releases = URL(string: "https://github.com/lkangd/winductor/releases")!
}

struct AboutPage: View {
    @ObservedObject var model: MainWindowModel
    @Environment(\.openURL) private var openURL

    /// 36pt 应用图标（BrandAssets 不缓存；取不到则不显示）
    private static let appIcon = BrandAssets.appIcon(side: 36)

    var body: some View {
        PageScroll {
            HStack(alignment: .center, spacing: 10) {
                Text("Winductor").font(.system(size: 34, weight: .heavy))
                if let icon = Self.appIcon {
                    Image(nsImage: icon).frame(width: 36, height: 36)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                infoRow("c.circle") { Text("lkangd") }
                infoRow("globe") {
                    Link(AboutLinks.repositoryText, destination: AboutLinks.repository)
                        .help(AboutLinks.repository.absoluteString)
                }
                infoRow("rectangle.3.group") { Text(model.state.aboutStatsText) }
            }
            .padding(.top, 10)
            SectionDivider()
            HStack(spacing: 12) {
                FieldLabel(text: "版本 \(model.version)")
                Button { openURL(AboutLinks.releases) } label: {
                    HStack(spacing: 3) {
                        Text("发行说明")
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                }
                .contentButtonStyle()
            }
        }
    }

    private func infoRow(_ symbol: String, @ViewBuilder _ text: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).resizable().scaledToFit().frame(width: 13, height: 13).foregroundStyle(.secondary)
            text().font(.system(size: 13))
        }
    }
}
