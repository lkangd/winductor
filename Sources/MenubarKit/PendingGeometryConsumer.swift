import Core
import Dispatch
import Foundation
import RestoreEngine
import SnapshotEngine
import SpaceAdapter

/// 后台窗延迟几何的消费轮询（RuntimeAssembly 专用）。
///
/// 背景：CGWindowList 的 isOnscreen 对跨 Space 后台窗恒为 true，「不可见 → 可见」迁移
/// 在跨 Space 场景永不触发，pending 几何永不消费（11-03 实测：WeChat 恢复时 elementInvalid
/// 记 pending，此后一直「可见」却再无补写时机）。
///
/// 消费判定（每 2s 一次，pending 非空才做 SLS 读）：窗当前 Space ∈ 任一屏活跃 Space
/// = 用户能看到它 = AX 可写 → 应用一次（每窗单次，一次性语义不变）。
/// 恢复/撤销管线运行期间与 SnapshotEngine 一起挂起（SLS 并发冲突面，见 PollPausingRestorer）。
final class PendingGeometryConsumer {
    private let store: DeferredGeometryStore
    private let applier: DeferredGeometryApplier
    private let adapter: SpaceAdapter
    private let snapshotEngine: SnapshotEngine
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "wlr.pending-geometry")

    init(store: DeferredGeometryStore, applier: DeferredGeometryApplier,
         adapter: SpaceAdapter, snapshotEngine: SnapshotEngine) {
        self.store = store
        self.applier = applier
        self.adapter = adapter
        self.snapshotEngine = snapshotEngine
    }

    /// 启动轮询（app 根装配时调用；与 SnapshotEngine 同生命周期）
    func start(interval: TimeInterval = 2.0) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// 单轮消费（测试直接调用；pending 空 / 管线挂起时零成本返回）
    func tick() {
        guard !snapshotEngine.pollingSuspended else { return }
        let pending = store.load()
        guard !pending.isEmpty else { return }
        guard let active = try? Set(adapter.currentSpaceIDs().values),
              let byWindow = try? adapter.spaceIDsByWindowID() else { return }
        for entry in pending {
            guard let wid = UInt32(exactly: entry.windowID),
                  let sid = byWindow[wid], active.contains(sid) else { continue }
            _ = applier.applyIfPending(windowID: wid)
        }
    }
}
