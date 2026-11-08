import Foundation

// StructuredLog.swift — 结构化日志助手（spec §10.4）。票 11 拥有本文件。
// 行格式（票 14/15/16/17 恢复管线沿用，勿改拼写）：
//   [restore] L<n> wid=<cgwindowid> app=<bundleID> action=<move-to-space|position|fullscreen|minimize>
//             target=<displayUUID/spaceIndex> before=<…> after=<…> result=ok|skip|fail
//   [degrade] layer=L<n> reason=<probe-miss|no-op> detail=<…>
//   [snapshot] action=<write|load|quarantine> path=<文件名> result=ok|fail detail=<…>
//     ↑ 存储层自检行，票 11 新增、票 12 沿用；spec §10.4 只定义了前两种
//   [preset] action=<add|overwrite|rename|delete|set-auto|alias|record-restored> topology=<拓扑键>
//            [preset=<id>] result=ok [detail=<…>]                                   （预设存储，display-presets 票 02）
//   [preset] action=<load|quarantine> path=<文件名> result=ok|fail detail=<…>        （预设文件版本拒用 / 损坏隔离）
//
// 管线级扩展行登记（评审修复项：非逐层逐窗口行，spec §10.4 未定义；拼写冻结，恢复管线沿用）：
//   [restore] abort reason=no-active-display
//   [undo]    abort reason=no-active-display|undo-snapshot-missing|undo-snapshot-rejected|undo-snapshot-corrupt
//             path=<文件名> [detail=<…>] [quarantine=<文件名|failed>]
//   [restore] done ok=<n> skip=<n> fail=<n> matched=<n> untouched=<n>              （整轮恢复汇总）
//   [undo]    done ok=<n> skip=<n> fail=<n> pending=<n> matched=<n> untouched=<n>  （整轮撤销汇总）
//   [restore] space-merge wid=<cgwindowid> app=<bundleID> display=<displayUUID>
//             snapshotIndex=<n> mergedTo=<n>                                     （快照多出 Space 就近并入，§6.7）
//   [restore] detail wid=<cgwindowid> app=<bundleID> action=<action> error=<error> （失败详情独立行，§6.3；
//             幂等达标变体后缀 detail=already-at-target）
//   [undo]    action=load path=<文件名> result=ok detail=<…>                      （撤销入口读回滚快照自检）
//   [restore|undo] perf prep=<ms> l2=<ms> ax-index=<ms> l1=<ms> l3l4=<ms> total=<ms> （管线分段计时，紧邻 done 行之前）
//   [restore|undo] action=exclusive-drain result=timeout detail=shared-in-flight=<n> waited=<ms>ms
//                                                       （独占前在途 shared 未排空即开始，SkyLightSession）
//   [restore] deferred wid=<cgwindowid> result=stale detail=pipeline-started-during-apply
//                                                       （补写 AX 写期间管线开工：不消费不计失败）
// 逐窗口行的注册扩展键（restoreLine 尾部可选追加，接在冻结字段之后）：
//   skip 行可附 reason=<跳过原因> 与 detail=<补充详情>；wid=0 = 未配对实况窗（规划期无 cgwindowid 可引）。
// 文件 sink：落盘行前缀 ISO8601 时间戳；目录延迟创建（首次写入才建，
// 默认 ~/Library/Application Support/Winductor/logs/）。

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
    /// spec §10.4 原文格式的恢复行。reason/detail = 逐窗口 skip 行的注册扩展键（文件头登记），
    /// 缺省 nil 时输出与冻结格式逐字节一致。
    public static func restoreLine(layer: Int, wid: UInt32, app: String, action: RestoreAction,
                                   target: String, before: String, after: String, result: RestoreOutcome,
                                   reason: String? = nil, detail: String? = nil) -> String {
        var line = "[restore] L\(layer) wid=\(wid) app=\(app) action=\(action.rawValue)"
        + " target=\(target) before=\(before) after=\(after) result=\(result.rawValue)"
        if let reason { line += " reason=\(reason)" }
        if let detail { line += " detail=\(detail)" }
        return line
    }

    /// spec §10.4 原文格式的降级行
    public static func degradeLine(layer: Int, reason: String, detail: String) -> String {
        "[degrade] layer=L\(layer) reason=\(reason) detail=\(detail)"
    }
}

/// 日志文件 sink：单文件追加、目录延迟创建；轮转策略留给票 10/19 接线时定。
/// 线程安全：NSLock 串行化写入与目录创建标志。
public final class FileLogSink: LogWriting {
    private let lock = NSLock()
    private let fileURL: URL
    private let directory: URL
    // lock 保护；编译器看不见锁保护，用 nonisolated(unsafe) 标注（Swift 5.10+）
    nonisolated(unsafe) private var directoryEnsured = false

    public init(directory: URL, fileName: String) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(fileName)
    }

    public func write(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
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

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
