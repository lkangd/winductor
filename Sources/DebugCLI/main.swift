import Foundation

// DebugCLI — 调试命令面板（演示面/验收驱动）。
// 归属：票 13 加 list-spaces / move-window / probe；票 12 加 snapshot-now；
//       票 14 加 restore；票 16 加 undo；retro 优化加 simulate-restore（多屏干跑免硬件）。
// display-presets 票 09：命令面向预设——snapshot-now 保存为预设、restore/simulate-restore 按预设名、新增 list-presets。
// 本文件只做注册与分发，每个子命令一个文件，缩小并行票冲突面。

let registry: [String: (run: ([String]) -> Int32, usage: String)] = [
    "list-presets": (ListPresets.run, ListPresets.usage),
    "list-spaces": (ListSpaces.run, ListSpaces.usage),
    "move-window": (MoveWindow.run, MoveWindow.usage),
    "probe": (Probe.run, Probe.usage),
    "restore": (Restore.run, Restore.usage),
    "simulate-restore": (SimulateRestore.run, SimulateRestore.usage),
    "snapshot-now": (SnapshotNow.run, SnapshotNow.usage),
    "undo": (Undo.run, Undo.usage),
]

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, let entry = registry[command] else {
    // 无子命令 / 未知子命令 / help：列出全部子命令用法
    let help = args.first.map { ["help", "--help", "-h"].contains($0) } ?? false
    print(help ? "debug: 子命令" : "debug: no subcommand")
    for name in registry.keys.sorted() { print("  \(registry[name]!.usage)") }
    exit(help ? 0 : 2)
}
exit(entry.run(Array(args.dropFirst())))
