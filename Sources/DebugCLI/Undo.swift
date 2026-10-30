import Core
import Foundation
import RestoreEngine
import SpaceAdapter

// Undo.swift — 调试子命令 undo（票 16 验收：撤销入口 + spec §6.3/§8.6 单层/两段式撤销）。
// 用法：undo
// 读回滚快照 undo-<拓扑键>.json 整体回滚（把恢复前实况当作恢复目标跑一次恢复语义，spec §7.4）；
// 含全屏应用时两段式：第一段跳过全屏并打印 09 八文案（§8.6 逐字，N = fullscreenPendingCount），
// 用户按 Esc（全屏 Space 自动销毁、窗口归原 Space）后再次执行本命令补完几何回滚。
// 回滚快照缺失/损坏 → 入口安全禁用：明确报错不崩溃（损坏文件由引擎按 §7.4 隔离挪开）。
// 撤销后回滚快照保留（重复执行幂等无害，至下次 restore 才被覆盖）。
// 退出码：0 = 完成（failCount=0）；1 = 管线中止或存在失败；2 = 回滚快照缺失/损坏（入口禁用）。

enum Undo {
    static let usage = "usage: swift run DebugCLI undo"

    // args 已由 main.swift 去除子命令名（票 13 注册表约定）
    static func run(_ args: [String]) -> Int32 {
        guard args.isEmpty else {
            print(usage)
            return 2
        }
        let log = ConsoleLogSink.shared
        let store = SnapshotStore(directory: SnapshotStore.defaultDirectory, log: log)
        let engine = RestoreEngine(
            store: store,
            spaces: SpaceAdapterBridge(SpaceAdapter(log: log)),
            log: log)
        do {
            let report = try engine.undo()
            print("undo 完成：ok=\(report.okCount) skip=\(report.skipCount) fail=\(report.failCount) "
                + "matched=\(report.matchedCount) untouched=\(report.untouchedLiveCount)")
            if let text = report.twoStageNotificationText {
                // 两段式第一段：RestoreEngine 层产出的 §8.6 逐字文案；
                // 系统通知投递归票 19 菜单栏接线，此处直接打印
                print(text)
            }
            return report.failCount == 0 ? 0 : 1
        } catch RestoreEngineError.undoSnapshotMissing {
            print("FAIL: 无可用回滚快照（undo-<拓扑键>.json 不存在），撤销入口禁用（spec §7.4：仅文件存在时可用）")
            return 2
        } catch RestoreEngineError.undoSnapshotCorrupt(let why) {
            print("FAIL: 回滚快照不可用，撤销入口禁用（损坏文件已按 §7.4 隔离挪开，下次恢复将重写）：\(why)")
            return 2
        } catch RestoreEngineError.noActiveDisplay {
            print("FAIL: 无活动显示器，撤销中止")
            return 1
        } catch {
            print("FAIL: \(error)")
            return 1
        }
    }
}
