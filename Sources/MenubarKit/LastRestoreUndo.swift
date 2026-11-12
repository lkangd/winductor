import Foundation
import RestoreEngine

/// 撤销执行接缝：生产用 RestoreEngine，测试替换执行与回滚快照可用性。
public protocol UndoPerforming: AnyObject {
    func canUndo() -> Bool
    func undo() throws -> UndoReport
}

extension RestoreEngine: UndoPerforming {}

/// 三个呈现入口共用的撤销 module：隐藏准入、后台执行、通知与完成刷新。
/// 可用性是即时的展示建议，不是后续执行的保证；不缓存、不防抖、不改变引擎独占策略。
public final class LastRestoreUndo {
    private let performer: UndoPerforming
    private let readiness: () -> Bool
    private let enqueue: (@escaping @Sendable () -> Void) -> Void
    private let notifier: SystemNotifying
    private let refresh: () -> Void

    public init(performer: UndoPerforming,
                readiness: @escaping () -> Bool,
                enqueue: @escaping (@escaping @Sendable () -> Void) -> Void = { work in
                    DispatchQueue(label: "winductor.restore", qos: .userInitiated).async(execute: work)
                },
                notifier: SystemNotifying,
                refresh: @escaping () -> Void) {
        self.performer = performer
        self.readiness = readiness
        self.enqueue = enqueue
        self.notifier = notifier
        self.refresh = refresh
    }

    /// 主线程同步读取；未就绪时短路，不读回滚快照。
    public func isAvailable() -> Bool {
        readiness() && performer.canUndo()
    }

    /// 菜单旧回调、恢复告知：只复核权限，不追加 canUndo 门，保留实际执行的失败通知。
    /// 主线程调用；测试执行器可以同步完成。排队回调不保活本 module。
    public func request() {
        guard readiness() else { return }
        enqueue { [weak self] in self?.performAndNotify() }
    }

    /// 通用页：点击时重查可用性，不可用则静默返回；随后复用同一执行流程。
    public func requestIfAvailable() {
        guard isAvailable() else { return }
        request()
    }

    private func performAndNotify() {
        // 排队期间权限可能变化；此处拒绝不通知、不刷新。
        guard readiness() else { return }
        do {
            let report = try performer.undo()
            if report.isTwoStageFirstPass {
                notifier.deliver(title: "撤销完成", body: report.twoStageNotificationText ?? "")
            } else {
                notifier.deliver(title: "撤销完成",
                                 body: "撤销完成：\(report.okCount) 窗口归位、\(report.skipCount) 跳过、\(report.failCount) 失败")
            }
        } catch RestoreEngineError.undoSnapshotMissing {
            notifier.deliver(title: "撤销失败", body: "撤销失败：无可用回滚快照")
        } catch RestoreEngineError.undoSnapshotCorrupt {
            notifier.deliver(title: "撤销失败", body: "撤销失败：回滚快照不可用（已按 §7.4 隔离，下次恢复重写）")
        } catch RestoreEngineError.noActiveDisplay {
            notifier.deliver(title: "撤销失败", body: "撤销失败：无活动显示器")
        } catch {
            notifier.deliver(title: "撤销失败", body: "撤销失败：\(String(describing: error))")
        }
        let work = { [refresh] in refresh() }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
