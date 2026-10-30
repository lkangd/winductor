import Foundation

// DebugCLI — 调试命令面板（演示面/验收驱动）。
// 归属：票 13 加 list-spaces / move-window；票 12 可加 snapshot-now；
//       票 14 加 restore；票 16 加 undo。
// 本文件只做注册与分发，每个子命令一个文件，缩小并行票冲突面。

let registry: [String: ([String]) -> Int32] = [
    "list-spaces": ListSpaces.run,
    "move-window": MoveWindow.run,
    "probe": Probe.run,
]

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, let handler = registry[command] else {
    print("debug: no subcommand (\(registry.keys.sorted().joined(separator: " | ")))")
    exit(2)
}
exit(handler(Array(args.dropFirst())))
