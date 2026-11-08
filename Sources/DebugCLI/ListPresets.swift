import Core
import Foundation

// ListPresets.swift — 调试子命令 list-presets（票 09）：只读列出预设库全部拓扑与预设，
// 标当前拓扑、自动预设、最近恢复预设；输出格式由 Core.PresetListing 给出。
// 用法：swift run DebugCLI list-presets

enum ListPresets {
    static let usage = "usage: swift run DebugCLI list-presets"

    // args 已由 main.swift 去除子命令名（票 13 注册表约定）
    static func run(_ args: [String]) -> Int32 {
        guard args.isEmpty else { print(usage); return 2 }
        let store = PresetStore(directory: PresetStore.defaultDirectory)
        print("预设库：\(store.directory.path)")
        print(PresetListing.render(store.topologies(), current: ObservedTopology.current()))
        return 0
    }
}
