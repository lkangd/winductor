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
    private let queue = DispatchQueue(label: "winductor.pending-geometry")

    init(store: DeferredGeometryStore, applier: DeferredGeometryApplier,
         adapter: SpaceAdapter, snapshotEngine: SnapshotEngine, log: LogWriting? = nil) {
        self.store = store
        self.applier = applier
        self.adapter = adapter
        self.snapshotEngine = snapshotEngine
        self.log = log
    }

    /// Space 切换 → 补写的延迟（秒）：只避开切换动画最初一段；仍未进 AX 树的窗由 Applier 的
    /// elementInvalid 快速重试兜住（不耗失败额度），不必为保守再多等
    static let spaceChangeDelay: TimeInterval = 0.15

    /// 启动轮询（app 根装配时调用；与 SnapshotEngine 同生命周期）。
    /// 除 2s 轮询外，Space 切换时立即补一轮：后台窗正是在用户切过去时才可写，等下一个 2s tick
    /// 用户会看着窗口迟迟才归位（11-03 实测反馈「能感觉到有些窗口在慢慢恢复」）
    func start(interval: TimeInterval = 2.0,
               center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { self.tick(source: "timer") }
        t.resume()
        timer = t
        self.center = center
        spaceObserver = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                           object: nil, queue: nil) { _ in
            // 串行队列：与 timer tick 不重叠
            self.queue.asyncAfter(deadline: .now() + Self.spaceChangeDelay) { self.tick(source: "space-change") }
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

    /// 单轮消费（测试直接调用；pending 空 / 管线挂起时零成本返回）。
    /// source 只进日志（space-change / timer）：实测量「切 Space → 补写」延迟
    func tick(source: String = "timer") {
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
        let shouldYield = { [snapshotEngine] in snapshotEngine.pollingSuspended }
        Self.consume(pending: pending, activeSpaceIDs: active, spaceByWindow: byWindow, shouldYield: shouldYield) {
            log?.write("[restore] action=deferred-consume source=\(source) eligible=\($0.count) pending=\(pending.count)")
            applier.applyPending(windowIDs: $0, shouldYield: shouldYield)
        }
    }

    /// 窗在任一屏活跃 Space 的 pending 条目（= 用户能看到 = AX 可写）
    static func eligibleWindowIDs(pending: [PendingGeometryEntry], activeSpaceIDs: Set<Int64>,
                                  spaceByWindow: [UInt32: Int64]) -> [UInt32] {
        pending.map(\.windowID).filter { wid in
            spaceByWindow[wid].map(activeSpaceIDs.contains) ?? false
        }
    }

    /// 补写调度：只补写窗在活跃 Space 的条目，整批交 Applier（每轮按 app 建一次 AX 索引、并发写、
    /// 窗未进 AX 树的短间隔重试）。阻塞至本批返回（下一 tick 不重叠）；恢复管线已开始则让出。
    static func consume(pending: [PendingGeometryEntry], activeSpaceIDs: Set<Int64>,
                        spaceByWindow: [UInt32: Int64], shouldYield: () -> Bool,
                        applyBatch: ([UInt32]) -> Void) {
        let eligible = eligibleWindowIDs(pending: pending, activeSpaceIDs: activeSpaceIDs, spaceByWindow: spaceByWindow)
        guard !eligible.isEmpty, !shouldYield() else { return }
        applyBatch(eligible)
    }
}
