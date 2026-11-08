import Foundation

// PresetListing — DebugCLI list-presets 的人读输出：列出全部拓扑与预设，标当前拓扑、自动、最近恢复。
// 每拓扑一块（块间空行）：首行键 +（别名）+ 当前标记；次行屏名与分辨率；之后每预设一行（保存时间升序）。
// 当前拓扑没存过或镜像中时末尾补一行说明。

public enum PresetListing {
    public static func render(_ topologies: [PresetTopology], current: ObservedTopology,
                              timeZone: TimeZone = .current) -> String {
        let formatter = PresetDateFormat.savedAt.formatter(timeZone: timeZone)
        let currentKey = current.isMirrored ? nil : current.identity.key

        var blocks = topologies.map { topology in
            var head = "拓扑 \(topology.key)"
            if let alias = topology.alias { head += "（\(alias)）" }
            if topology.key == currentKey { head += "  ← 当前" }
            var lines = [head]
            lines.append("  屏：" + topology.displays
                .map { "\($0.name) \($0.pixelWidth)×\($0.pixelHeight)" }
                .joined(separator: " · "))
            for preset in topology.presets {
                var line = "  · \(preset.name)  \(formatter.string(from: preset.savedAt))"
                if preset.isAuto { line += "  [自动]" }
                if preset.id == topology.lastRestoredPresetID { line += "  [最近恢复]" }
                lines.append(line + "  id=\(preset.id)")
            }
            return lines.joined(separator: "\n")
        }
        // 当前拓扑不在列表里（没存过）/ 镜像中：单独说明，免得误以为列表漏了
        if let currentKey {
            if !topologies.contains(where: { $0.key == currentKey }) {
                blocks.append("当前拓扑 \(currentKey)：无预设")
            }
        } else {
            blocks.append("当前：镜像中，无拓扑")
        }
        return blocks.joined(separator: "\n\n")
    }
}
