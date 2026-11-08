import Core
import Foundation
import RestoreEngine

// SimulateRestore.swift — 调试子命令 simulate-restore（retro 优化：多屏行为免硬件可验；display-presets 票 09 起按预设名）。
// 用法：simulate-restore <预设名> <fixture.json> [--topology <拓扑键>]
// fixture 描述显示器/Space/存活窗（坐标为全局绝对点），注入恢复管线全部接缝后干跑真实管线：
// 只记录动作不动真实窗口；回滚快照照 §7.4 照写但落临时目录，不碰真实预设库，也不记最近恢复。
// 预设在 fixture 描述的拓扑下按名称查（即「接上这套屏会恢复成什么样」）；
// --topology 改在指定拓扑下查（手写 fixture 的 UUID/排列对不上已存拓扑时用，键见 list-presets）。
// 退出码：0 = 完成（failCount=0）；1 = 管线中止或存在失败；2 = 用法/文件/解析错误或无此预设。

enum SimulateRestore {
    static let usage = "usage: swift run DebugCLI simulate-restore <预设名> <fixture.json> [--topology <拓扑键>]"

    // args 已由 main.swift 去除子命令名（票 13 注册表约定）
    static func run(_ args: [String]) -> Int32 {
        var positional: [String] = []
        var topologyKey: String?
        var i = args.startIndex
        while i < args.endIndex {
            if args[i] == "--topology" {
                guard args.indices.contains(i + 1) else { print(usage); return 2 }
                topologyKey = args[i + 1]
                i += 2
            } else {
                positional.append(args[i])
                i += 1
            }
        }
        guard positional.count == 2 else {
            print(usage)
            return 2
        }
        let presetName = positional[0]
        let fixtureURL = URL(fileURLWithPath: positional[1])
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            print("FAIL: fixture 文件不存在：\(fixtureURL.path)")
            return 2
        }

        let fixture: SimulatedTopologyFixture
        do {
            fixture = try JSONDecoder().decode(SimulatedTopologyFixture.self, from: Data(contentsOf: fixtureURL))
        } catch {
            print("FAIL: fixture 解析失败：\(error)")
            return 2
        }

        let key = topologyKey ?? fixture.topologyIdentity.key
        guard let preset = lookupPreset(named: presetName,
                                        topologyKey: key,
                                        store: PresetStore(directory: PresetStore.defaultDirectory)) else {
            return 2
        }
        let snapshot = preset.snapshot

        let log = ConsoleLogSink.shared
        let storeDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("simulate-restore-\(UUID().uuidString)")
        print("simulate-restore：干跑（不动真实窗口；回滚快照写 \(storeDir.path)）")
        print("预设：「\(preset.name)」 id=\(preset.id) topology=\(key)\(topologyKey == nil ? "（fixture 拓扑）" : "")")
        print("fixture：displays=\(fixture.displays.count) spaces=\(fixture.spaces.count) windows=\(fixture.windows.count)")

        do {
            let (report, actions) = try SimulatedRestore.run(
                snapshot: snapshot, fixture: fixture, log: log, storeDirectory: storeDir)
            print("simulate-restore 完成：ok=\(report.okCount) skip=\(report.skipCount) fail=\(report.failCount) "
                + "matched=\(report.matchedCount) untouched=\(report.untouchedLiveCount)")
            print("动作：bridge=\(actions.bridgeMoves.count) directMinimized=\(actions.minimizedDirectMoves.count) "
                + "geometry=\(actions.geometryWrites.count) fullscreen=\(actions.fullscreenSets.count) "
                + "minimize=\(actions.minimizeSets.count)")
            return report.failCount == 0 ? 0 : 1
        } catch RestoreEngineError.noActiveDisplay {
            print("FAIL: fixture 无显示器，恢复中止")
            return 1
        } catch RestoreEngineError.undoSnapshotWriteFailed(let why) {
            print("FAIL: 回滚快照写失败，恢复中止（spec §7.4）：\(why)")
            return 1
        } catch {
            print("FAIL: \(error)")
            return 1
        }
    }
}
