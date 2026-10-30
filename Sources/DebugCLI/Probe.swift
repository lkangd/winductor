import Core
import Foundation
import SpaceAdapter

// Probe — 启动探针演示面（票 13 验收第 3 项；spec §10.2 版本守卫）。
// 只读：按层打印 bridge(L2)/fullscreen(L3)/minimized(L4) 可用性与原因，绝不崩溃。

enum Probe {
    static let usage = "usage: swift run DebugCLI probe"

    static func run(_ args: [String]) -> Int32 {
        guard args.isEmpty else { print(usage); return 2 }
        let adapter = SpaceAdapter(log: ConsoleLogSink.shared)
        for p in adapter.probeLayers() {
            let state = p.available ? "available" : "UNAVAILABLE"
            var line = "layer L\(p.layer.layerNumber) \(p.layer.rawValue): \(state)"
            if !p.reason.isEmpty { line += " reason=\(p.reason)" }
            if !p.detail.isEmpty { line += " detail=\(p.detail)" }
            print(line)
        }
        return 0
    }
}
