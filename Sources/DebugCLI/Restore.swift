import Core
import Foundation
import RestoreEngine
import SnapshotEngine
import SpaceAdapter

// Restore.swift — 调试子命令 restore（票 14 验收：restore 调试命令 + spec §6.3 单轮 best-effort；display-presets 票 09 起按预设名）。
// 用法：restore <预设名>
// 在当前拓扑下按名称取预设（仅当前拓扑，display-presets spec §5.2）→ 跑一轮恢复管线
// （回滚快照落盘 → L2 桥接移窗 → L1 几何摆位，one-shot 放完即停）→ 记录为最近恢复（VerifyCLI 缺省基准）。
// 输出成功/跳过/失败计数与回滚快照落点。逐窗口结构化日志经 ConsoleLogSink 打到 stdout。
// 退出码：0 = 完成（failCount=0）；1 = 管线中止、存在失败或镜像中；2 = 用法错误或当前拓扑无此预设。

enum Restore {
    static let usage = "usage: swift run DebugCLI restore <预设名>（预设名见 list-presets）"

    // args 已由 main.swift 去除子命令名（票 13 注册表约定）
    static func run(_ args: [String]) -> Int32 {
        guard args.count == 1 else {
            print(usage)
            return 2
        }
        let topology = ObservedTopology.current()
        guard !topology.isMirrored else {
            print("FAIL: 镜像中，无拓扑，不恢复（spec §3.3）")
            return 1
        }
        let log = ConsoleLogSink.shared
        let store = PresetStore(directory: PresetStore.defaultDirectory, log: log)
        let key = topology.identity.key
        guard let preset = lookupPreset(named: args[0], topologyKey: key, store: store) else { return 2 }
        print("restore：预设「\(preset.name)」 id=\(preset.id) topology=\(key)")
        let engine = RestoreEngine(
            store: store,
            spaces: SpaceAdapterBridge(SpaceAdapter(log: log)),
            log: log)
        do {
            let report = try engine.restore(snapshot: preset.snapshot)
            // 与触发链同口径：管线跑完即记最近恢复（失败条目不影响记录）
            do {
                try store.recordRestored(presetID: preset.id, topologyKey: key)
            } catch {
                print("WARN: 最近恢复记录写失败：\(error)")
            }
            print("restore 完成：ok=\(report.okCount) skip=\(report.skipCount) fail=\(report.failCount) "
                + "matched=\(report.matchedCount) untouched=\(report.untouchedLiveCount)")
            if let undo = report.undoSnapshotURL {
                print("undo=\(undo.path)")
            }
            return report.failCount == 0 ? 0 : 1
        } catch RestoreEngineError.noActiveDisplay {
            print("FAIL: 无活动显示器，恢复中止")
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
