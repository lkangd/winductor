import Core
import Foundation

// Support.swift — DebugCLI 子命令共用小工具（票 13）。

/// 控制台 sink：把 Core.StructuredLog 行（[degrade] 等）原样打到 stdout，
/// 作为钩子路径验收的观察面（spec §10.2/§10.4）。
final class ConsoleLogSink: LogWriting {
    static let shared = ConsoleLogSink()
    private init() {}
    func write(_ line: String) { print(line) }
}
