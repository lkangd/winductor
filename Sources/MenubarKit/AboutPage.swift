import SwiftUI

// AboutPage.swift — 主窗口「关于」页（ui-refactor 票 03，spec §5.6，参照 Swish About，不要授权行）。
//   「Winductor」34pt heavy + 透明底应用主体（同行；票 08：无白底，可见主体高 = 标题字高，底边落在基线上）；
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

    /// 标题字体（与下方 Text 的 .system(size: 34, weight: .heavy) 同一字体，只用来取字高）
    static let titleFont = NSFont.systemFont(ofSize: 34, weight: .heavy)

    /// 透明底应用主体（已裁到可见外接框；取不到则不显示）
    private static let subject = BrandAssets.appIconSubject()

    /// 主体显示尺寸：高 = 标题字体大写字高（即「W」的高度），宽按原图比例
    static func subjectSize(for image: NSImage) -> CGSize {
        let height = titleFont.capHeight
        return CGSize(width: height * image.size.width / image.size.height, height: height)
    }

    var body: some View {
        PageScroll {
            // 首行基线对齐：图片的基线即其底边，故主体底边与「W」同落基线、顶边齐大写字高
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Winductor").font(.system(size: 34, weight: .heavy))
                if let subject = Self.subject {
                    let size = Self.subjectSize(for: subject)
                    Image(nsImage: subject).resizable().interpolation(.high).frame(width: size.width, height: size.height)
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
