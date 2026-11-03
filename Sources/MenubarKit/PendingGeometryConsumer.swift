import AppKit
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
///
/// 生命周期：start() 后由 timer 回调强持有自身（装配处只有局部变量；实测缺陷 11-03：
/// 曾用 [weak self]，装配函数返回即释放，pending 从未被消费），stop() 断环释放。
final class PendingGeometryConsumer {
    private let store: DeferredGeometryStore
    private let applier: DeferredGeometryApplier
    private let adapter: SpaceAdapter
    private let snapshotEngine: SnapshotEngine
    private let log: LogWriting?
    /// 上一次读失败的描述（同一失败只落一行日志，防 2s 轮询刷屏）
    private var lastReadFailure: String?
    private var timer: DispatchSourceTimer?
    private var spaceObserver: NSObjectProtocol?
    private var center: NotificationCenter?
    private let queue = DispatchQueue(label: "wlr.pending-geometry")

    init(store: DeferredGeometryStore, applier: DeferredGeometryApplier,
         adapter: SpaceAdapter, snapshotEngine: SnapshotEngine, log: LogWriting? = nil) {
        self.store = store
        self.applier = applier
        self.adapter = adapter
        self.snapshotEngine = snapshotEngine
        self.log = log
    }

    /// Space 切换 → 补写的延迟（秒）：切换动画期间新 Space 窗尚未进 AX 树，过早补写只会
    /// elementInvalid 白耗一次重试额度
    static let spaceChangeDelay: TimeInterval = 0.35

    /// 启动轮询（app 根装配时调用；与 SnapshotEngine 同生命周期）。
    /// 除 2s 轮询外，Space 切换时立即补一轮：后台窗正是在用户切过去时才可写，等下一个 2s tick
    /// 用户会看着窗口迟迟才归位（11-03 实测反馈「能感觉到有些窗口在慢慢恢复」）
    func start(interval: TimeInterval = 2.0,
               center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { self.tick() }
        t.resume()
        timer = t
        self.center = center
        spaceObserver = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                           object: nil, queue: nil) { _ in
            // 串行队列：与 timer tick 不重叠
            self.queue.asyncAfter(deadline: .now() + Self.spaceChangeDelay) { self.tick() }
        }
    }

    func stop() {
        if let spaceObserver { center?.removeObserver(spaceObserver) }
        spaceObserver = nil
        // 先清回调再 cancel：cancel 的源由 GCD 异步回收，回调里的强引用须同步断开
        timer?.setEventHandler(handler: nil)
        timer?.cancel()
        timer = nil
    }

    /// 单轮消费（测试直接调用；pending 空 / 管线挂起时零成本返回）
    func tick() {
        guard !snapshotEngine.pollingSuspended else { return }
        let pending = store.load()
        guard !pending.isEmpty else { return }
        let active: Set<Int64>
        let byWindow: [UInt32: Int64]
        do {
            active = Set(try adapter.currentSpaceIDs().values)
            byWindow = try adapter.spaceIDsByWindowID()
            lastReadFailure = nil
        } catch {
            let failure = "\(error)"
            if failure != lastReadFailure {
                log?.write("[restore] action=deferred-consume result=fail detail=space-read \(failure) pending=\(pending.count)")
                lastReadFailure = failure
            }
            return
        }
        Self.consume(pending: pending, activeSpaceIDs: active, spaceByWindow: byWindow,
                     shouldYield: { [snapshotEngine] in snapshotEngine.pollingSuspended },
                     apply: { [applier] wid in _ = applier.applyIfPending(windowID: wid) })
    }

    /// 补写调度：只补写窗在活跃 Space 的条目，并发执行——单条 AX 写可阻塞数秒（实测 Chrome 失败
    /// 每条 ~4.7s），串行时排在后面的窗（11-03 WeCom）等到用户下次拔屏都轮不到。
    /// 每条开工前检查让出（恢复管线已开始则不再补写）；阻塞至本批全部返回（下一 tick 不重叠）。
    static func consume(pending: [PendingGeometryEntry], activeSpaceIDs: Set<Int64>,
                        spaceByWindow: [UInt32: Int64], shouldYield: () -> Bool,
                        apply: @escaping @Sendable (UInt32) -> Void) {
        let eligible = pending.map(\.windowID).filter { wid in
            spaceByWindow[wid].map(activeSpaceIDs.contains) ?? false
        }
        guard !eligible.isEmpty, !shouldYield() else { return }
        withoutActuallyEscaping(shouldYield) { yield in
            let yieldBox = UncheckedBox(yield)
            DispatchQueue.concurrentPerform(iterations: eligible.count) { i in
                if yieldBox.value() { return }
                apply(eligible[i])
            }
        }
    }
}

/// concurrentPerform 闭包内调用非 Sendable 的让出判定（判定只读 pollingSuspended，线程安全）
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
