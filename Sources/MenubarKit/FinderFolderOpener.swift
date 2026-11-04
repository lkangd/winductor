import AppKit

// FinderFolderOpener.swift — 快照/日志目录的 Finder 入口（票 19，spec 09 四「应用内零管理界面」）。
// 目录不存在先创建（首启即点「打开日志文件夹」也能得到有效目录），再交 NSWorkspace 打开。

public enum FinderFolderOpener {
    /// 打开目录（默认生产实现：目录不存在则连同中间目录一并创建）
    public static func open(_ folder: URL, workspace: NSWorkspace = .shared) {
        if !FileManager.default.fileExists(atPath: folder.path) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                // 创建失败仍然尝试打开（可能是用户手动指走的目录）；失败信息交由系统呈现
            }
        }
        workspace.open(folder)
    }
}
