import Foundation

// RuntimeBundle.swift — 运行形态判定与源码树定位（ui-refactor 评审修复：BrandAssets 与 AppVersion 共用一处）。
// .app（make-app.sh 打包）内只读包内资源 / Info.plist，缺了也不回落源码树（避免开发机上掩盖打包漏拷）；
// 其余形态（swift run / swift test，Bundle.main 不是 .app）读源码树。

enum RuntimeBundle {
    /// bundle 是否为 .app（swift run 的可执行目录、xctest 宿主都不是）
    static func isApp(_ bundle: Bundle) -> Bool {
        bundle.bundleURL.pathExtension == "app"
    }

    /// 仓库根（本文件 Sources/MenubarKit/ → 仓库根，#filePath 推导）；只供非 .app 形态读源码树文件
    static let sourceTreeRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
