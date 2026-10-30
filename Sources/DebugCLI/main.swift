import Foundation

// DebugCLI — 调试命令面板（演示面/验收驱动）。
// 归属：票 13 加 list-spaces / move-window；票 12 可加 snapshot-now；
//       票 14 加 restore；票 16 加 undo。
// 保持每个子命令一个文件（如 ListSpaces.swift），main.swift 只做注册分发，
// 避免并行票在同一文件冲突。

// 票 12 注册：snapshot-now（实现见 SnapshotNow.swift）
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "snapshot-now" {
    exit(runSnapshotNow())
}

print("debug: no subcommand (list-spaces | move-window | snapshot-now | restore | undo)")
exit(2)
