import Core
import RestoreEngine
import SnapshotEngine

/// 恢复/撤销执行期间挂起 SnapshotEngine 轮询的包装器（RuntimeAssembly 专用）。
/// 背景：poller 每 2s 对全窗口做 SLS 采样，与恢复管线的 SLS 读并发冲突（SkyLight 非
/// 线程安全文档化 API），实测导致 managedSpaces 失败 → entries 空 → 整轮 L2 静默 skip。
/// 挂起是管线级独占：restore/undo 全程，结束后恢复轮询（下轮 pollNow 正常差分）。
final class PollPausingRestorer: SnapshotRestoring, UndoPerforming {
    private let base: RestoreEngine
    private let snapshotEngine: SnapshotEngine

    init(base: RestoreEngine, snapshotEngine: SnapshotEngine) {
        self.base = base
        self.snapshotEngine = snapshotEngine
    }

    func restore(snapshot: Snapshot) throws -> RestoreReport {
        snapshotEngine.pollingSuspended = true
        defer { snapshotEngine.pollingSuspended = false }
        return try base.restore(snapshot: snapshot)
    }

    func undo() throws -> UndoReport {
        snapshotEngine.pollingSuspended = true
        defer { snapshotEngine.pollingSuspended = false }
        return try base.undo()
    }

    func canUndo() -> Bool { base.canUndo() }
}
