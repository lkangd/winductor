import Foundation

// StructuredLog.swift — 结构化日志助手（spec §10.4）。票 11 拥有本文件。
// 行格式（票 14/15/16/17 恢复管线沿用，勿改拼写）：
//   [restore] L<n> wid=<cgwindowid> app=<bundleID> action=<move-to-space|position|fullscreen|minimize>
//             target=<displayUUID/spaceIndex> before=<…> after=<…> result=ok|skip|fail
//   [degrade] layer=L<n> reason=<probe-miss|no-op> detail=<…>
//   [snapshot] action=<write|load|quarantine> path=<文件名> result=ok|fail detail=<…>
//     ↑ 存储层自检行，票 11 新增、票 12 沿用；spec §10.4 只定义了前两种
// 文件 sink：落盘行前缀 ISO8601 时间戳；目录延迟创建（首次写入才建，
// 默认 ~/Library/Application Support/WindowLayoutRestorer/logs/）。

public protocol LogWriting: Sendable {
    func write(_ line: String)
}

public enum RestoreAction: String, Sendable {
    case moveToSpace = "move-to-space"
    case position
    case fullscreen
    case minimize
}

public enum RestoreOutcome: String, Sendable {
    case ok
    case skip
    case fail
}

public enum StructuredLog {
    /// spec §10.4 原文格式的恢复行
    public static func restoreLine(layer: Int, wid: UInt32, app: String, action: RestoreAction,
                                   target: String, before: String, after: String, result: RestoreOutcome) -> String {
        "[restore] L\(layer) wid=\(wid) app=\(app) action=\(action.rawValue)"
        + " target=\(target) before=\(before) after=\(after) result=\(result.rawValue)"
    }

    /// spec §10.4 原文格式的降级行
    public static func degradeLine(layer: Int, reason: String, detail: String) -> String {
        "[degrade] layer=L\(layer) reason=\(reason) detail=\(detail)"
    }
}

/// 日志文件 sink：单文件追加、目录延迟创建；轮转策略留给票 10/19 接线时定。
public final class FileLogSink: LogWriting {
    private let fileURL: URL
    private let directory: URL
    private let queue = DispatchQueue(label: "com.lkd.window-restore.logsink")
    private var directoryEnsured = false

    public init(directory: URL, fileName: String) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(fileName)
    }

    public func write(_ line: String) {
        queue.sync {
            if !directoryEnsured {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                directoryEnsured = true
            }
            let stamped = "\(Self.timestampFormatter.string(from: Date())) \(line)\n"
            if let data = stamped.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    // 首次写入：文件不存在则建
                    try? data.write(to: fileURL)
                }
            }
        }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
