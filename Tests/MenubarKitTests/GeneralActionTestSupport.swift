import Foundation
@testable import MenubarKit
@testable import RestoreEngine

/// 撤销、主窗口与装配测试共用的外部 adapter；被测流程始终使用真实 LastRestoreUndo。
final class TestUndoPerformer: UndoPerforming {
    var canUndoValue: Bool
    var availability: (() -> Bool)?
    var onUndo: (() -> Void)?
    var outcome: Result<UndoReport, Error> = .success(UndoReport(
        okCount: 5, skipCount: 0, failCount: 0, matchedCount: 5, untouchedLiveCount: 0,
        undoSnapshotURL: URL(fileURLWithPath: "/tmp/undo.json"), fullscreenPendingCount: 0))
    private let lock = NSLock()
    private var reads = 0
    private var calls = 0

    init(canUndo: Bool = false) { canUndoValue = canUndo }

    var availabilityReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var undoCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }

    func canUndo() -> Bool {
        lock.lock(); reads += 1; lock.unlock()
        return availability?() ?? canUndoValue
    }

    func undo() throws -> UndoReport {
        lock.lock(); calls += 1; lock.unlock()
        onUndo?()
        return try outcome.get()
    }
}

final class TestNotificationRecorder: SystemNotifying {
    var onDelivery: ((String, String) -> Void)?
    private let lock = NSLock()
    private var recorded: [(title: String, body: String)] = []
    var deliveries: [(title: String, body: String)] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }
    func deliver(title: String, body: String) {
        lock.lock(); recorded.append((title, body)); lock.unlock()
        onDelivery?(title, body)
    }
}

final class TestLoginItem: LoginItemServicing {
    var enabled = false
    var failure: Error?
    var onToggle: (() -> Void)?
    var isEnabled: Bool { enabled }
    func enable() throws { try change(to: true) }
    func disable() throws { try change(to: false) }
    private func change(to value: Bool) throws {
        onToggle?()
        if let failure { throw failure }
        enabled = value
    }
}
