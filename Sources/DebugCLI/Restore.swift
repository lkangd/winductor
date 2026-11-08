import Core
import Foundation
import RestoreEngine
import SnapshotEngine
import SpaceAdapter

// Restore.swift — 调试子命令 restore（票 14 验收：restore 调试命令 + spec §6.3 单轮 best-effort）。
// 用法：restore <snapshot路径>
// 读取快照 JSON → 跑一轮恢复管线（回滚快照落盘 → L2 桥接移窗 → L1 几何摆位，one-shot 放完即停），
// 输出成功/跳过/失败计数与回滚快照落点。逐窗口结构化日志经 ConsoleLogSink 打到 stdout。
// 退出码：0 = 完成（failCount=0）；1 = 管线中止或存在失败；2 = 用法/快照错误。

enum Restore {
    static let usage = "usage: swift run DebugCLI restore <snapshot路径>"

    // args 已由 main.swift 去除子命令名（票 13 注册表约定）
    static func run(_ args: [String]) -> Int32 {
        guard args.count == 1 else {
            print(usage)
            return 2
        }
        let url = URL(fileURLWithPath: args[0])
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("FAIL: 快照文件不存在：\(url.path)")
            return 2
        }
        let snapshot: Snapshot
        do {
            snapshot = try Snapshot.decode(from: Data(contentsOf: url))
        } catch SnapshotSchemaError.unsupportedVersion(let found, let supported) {
            print("FAIL: 快照版本过高拒用（found=\(found) supported=\(supported)，spec §7.3 不迁移）")
            return 2
        } catch {
            print("FAIL: 快照解析失败：\(error)")
            return 2
        }

        let log = ConsoleLogSink.shared
        let store = PresetStore(directory: PresetStore.defaultDirectory, log: log)
        let engine = RestoreEngine(
            store: store,
            spaces: SpaceAdapterBridge(SpaceAdapter(log: log)),
            log: log)
        do {
            let report = try engine.restore(snapshot: snapshot)
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
