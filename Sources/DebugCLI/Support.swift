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

/// 按预设名在指定拓扑下取预设（restore / simulate-restore 共用）；找不到时打印当前可用名并返回 nil
func lookupPreset(named name: String, topologyKey: String, store: PresetStore) -> Preset? {
    let topology = store.topology(key: topologyKey)
    if let preset = topology?.preset(named: name) { return preset }
    let available = topology?.presets.map { "「\($0.name)」" }.joined(separator: " ") ?? ""
    print("FAIL: 拓扑 \(topologyKey) 下没有名为「\(name)」的预设；可用：\(available.isEmpty ? "（无）" : available)"
        + "（全部见 list-presets）")
    return nil
}
