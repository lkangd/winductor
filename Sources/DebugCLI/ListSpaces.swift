import Core
import Foundation
import SpaceAdapter

// ListSpaces — 只读枚举每屏 Space（spec §5.1；票 13 验收第 1 项）。
// 输出：每屏稳定 UUID + Space 列表（每屏 1 起 index、kind 0=用户桌面 / 4=全屏）+ 当前 Space。

enum ListSpaces {
    static let usage = "usage: swift run DebugCLI list-spaces"

    static func run(_ args: [String]) -> Int32 {
        guard args.isEmpty else { print(usage); return 2 }
        let adapter = SpaceAdapter(log: ConsoleLogSink.shared)
        do {
            let spaces = try adapter.managedSpaces()
            let current = try adapter.currentSpaceIDs()
            // 按首次出现顺序分组，保持 SLSCopyManagedDisplaySpaces 的显示器次序（dispIdx 引用它）
            var order: [String] = []
            var byDisplay: [String: [SpaceEntry]] = [:]
            for entry in spaces {
                if byDisplay[entry.displayUUID] == nil {
                    order.append(entry.displayUUID)
                    byDisplay[entry.displayUUID] = []
                }
                byDisplay[entry.displayUUID]?.append(entry)
            }
            for (dispIdx, uuid) in order.enumerated() {
                let cur = current[uuid].map(String.init) ?? "?"
                print("display #\(dispIdx) uuid=\(uuid) current=\(cur)")
                for entry in byDisplay[uuid] ?? [] {
                    let kindName = entry.kind == 0 ? "user" : (entry.kind == 4 ? "fullscreen" : "?kind=\(entry.kind)")
                    let marker = current[uuid] == entry.spaceID ? "  <== CURRENT" : ""
                    print("  space #\(entry.index) id64=\(entry.spaceID) kind=\(entry.kind)(\(kindName))\(marker)")
                }
            }
            return 0
        } catch {
            print("FAIL list-spaces: \(error)")
            return 1
        }
    }
}
