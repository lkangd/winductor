import AppKit
import AXFacade
import Core
import CoreGraphics
import Foundation
import SnapshotEngine

// DeferredGeometry.swift — 后台窗延迟几何（实测缺陷：AX 树只暴露可见 Space 的窗口，
// 恢复时后台窗几何写报 elementInvalid；一次性语义的保留形态 = 每窗延迟单次应用：
// restore 时记录 pending，该窗所在 Space 变为活跃时由 Applier 补写一次，之后不再管）。

/// 延迟几何模块：记录（恢复管线）、快照覆盖（SnapshotEngine 拍快照）、可见即补写（自驱轮询 + Space 切换）。
/// 内部：DeferredGeometryStore（pending 文件）+ DeferredGeometryApplier（AX 补写/回读/重试）。
public final class DeferredGeometry: DeferredGeometryPort, @unchecked Sendable {
    private let store: DeferredGeometryStore
    private let applier: DeferredGeometryApplier
    private let spaces: SpaceBridge
    private let session: SkyLightSession
    private let log: LogWriting?
    /// 补写串行队列（轮询 tick、Space 切换补一轮共用）
    private let queue = DispatchQueue(label: "winductor.deferred-geometry")

    public init(directory: URL, spaces: SpaceBridge, session: SkyLightSession,
                writer: WindowGeometryWriting = AXGeometryWriter(),
                displaysProvider: @escaping () -> [Displays.Info] = Displays.active,
                log: LogWriting? = nil,
                frameReader: (@Sendable (UInt32) -> CGRect?)? = nil) {
        store = DeferredGeometryStore(directory: directory)
        applier = DeferredGeometryApplier(store: store, writer: writer, displaysProvider: displaysProvider,
                                          log: log, frameReader: frameReader, session: session)
        self.spaces = spaces
        self.session = session
        self.log = log
    }

    /// 本轮恢复的 pending 整写替换（一次性语义：上轮未消费的 pending 作废）
    func replacePending(_ entries: [PendingGeometryEntry]) {
        store.save(entries)
    }

    /// 该窗有补写在途（只在排空超时后会与管线重叠）：管线须在自己写它之前查，若在途则写后再记一条 pending，
    /// 由下一轮补写在迟到的旧写之后重写本轮目标（补写队列串行，下一轮必在旧写返回之后）
    func isApplying(windowID: UInt32) -> Bool {
        applier.isApplying(windowID: windowID)
    }

    public func geometryOverrides() -> [UInt32: WindowGeometryOverride] {
        Dictionary(store.load().map {
            ($0.windowID, WindowGeometryOverride(displayUUID: $0.displayUUID, x: $0.x, y: $0.y, w: $0.w, h: $0.h))
        }, uniquingKeysWith: { a, _ in a })
    }

    /// Space 切换 → 补写的延迟（秒）：只避开切换动画最初一段；仍未进 AX 树的窗由 Applier 的
    /// elementInvalid 快速重试兜住（不耗失败额度），不必为保守再多等
    static let spaceChangeDelay: TimeInterval = 0.15

    private var timer: DispatchSourceTimer?
    private var spaceObserver: NSObjectProtocol?
    private var center: NotificationCenter?

    /// 启动自驱消费（app 根装配时调用）：2s 轮询 + Space 切换即补一轮（11-03 实测反馈
    /// 「能感觉到有些窗口在慢慢恢复」）。timer 回调强持有自身（实测缺陷 11-03：曾用 [weak self]，
    /// 装配处只有局部变量时随函数返回释放，pending 从未被消费），stop() 断环释放。
    public func start(interval: TimeInterval = 2.0,
                      center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { self.tick(source: "timer") }
        t.resume()
        timer = t
        self.center = center
        spaceObserver = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                           object: nil, queue: nil) { _ in
            self.queue.asyncAfter(deadline: .now() + Self.spaceChangeDelay) { self.tick(source: "space-change") }
        }
    }

    public func stop() {
        if let spaceObserver { center?.removeObserver(spaceObserver) }
        spaceObserver = nil
        // 先清回调再 cancel：cancel 的源由 GCD 异步回收，回调里的强引用须同步断开
        timer?.setEventHandler(handler: nil)
        timer?.cancel()
        timer = nil
    }

    /// 单轮消费（pending 空 / 管线独占时零成本返回）。
    /// 采样 isOnscreen 曾因缺键缺省 true 对跨 Space 后台窗恒为 true（display-presets 票 11 已改为缺键 = false），
    /// 可见性迁移在跨 Space 场景永不触发
    /// （11-03 实测：WeChat 记 pending 后一直「可见」却再无补写时机），故以「窗当前 Space ∈ 任一屏活跃 Space」
    /// 判定可写。source 只进日志（space-change / timer）：实测量「切 Space → 补写」延迟
    func tick(source: String = "timer") {
        _ = session.shared { tickShared(source: source) }
    }

    /// 上一次读失败的描述（同一失败只落一行日志，防 2s 轮询刷屏；只在串行队列/单测线程访问）
    private var lastReadFailure: String?

    private func tickShared(source: String) {
        let pending = store.load()
        guard !pending.isEmpty else { return }
        let active: Set<Int64>
        let byWindow: [UInt32: Int64]
        do {
            (active, byWindow) = try session.slsRead {
                (try spaces.activeSpaceIDs(), try spaces.spaceIDsByWindowID())
            }
            lastReadFailure = nil
        } catch {
            let failure = "\(error)"
            if failure != lastReadFailure {
                log?.write("[restore] action=deferred-consume result=fail detail=space-read \(failure) pending=\(pending.count)")
                lastReadFailure = failure
            }
            return
        }
        let eligible = pending.map(\.windowID).filter { byWindow[$0].map(active.contains) ?? false }
        guard !eligible.isEmpty, !session.shouldYield else { return }
        log?.write("[restore] action=deferred-consume source=\(source) eligible=\(eligible.count) pending=\(pending.count)")
        applier.applyPending(windowIDs: eligible, shouldYield: { [session] in session.shouldYield })
    }
}

/// 单条延迟几何：windowID + 目标屏 + 归一比例坐标（快照口径）
public struct PendingGeometryEntry: Codable, Equatable, Sendable {
    public let windowID: UInt32
    public let displayUUID: String
    public let x: Double, y: Double, w: Double, h: Double
    /// 已失败的补写次数（nil = 0；旧文件无此键兼容解码）
    public var failedAttempts: Int?

    public init(windowID: UInt32, displayUUID: String, x: Double, y: Double, w: Double, h: Double,
                failedAttempts: Int? = nil) {
        self.windowID = windowID
        self.displayUUID = displayUUID
        self.x = x; self.y = y; self.w = w; self.h = h
        self.failedAttempts = failedAttempts
    }
}

/// pending 集合的 JSON 文件存取（restore 结束整写替换 = 上轮 pending 作废，一次性语义）
public final class DeferredGeometryStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(directory: URL, fileName: String = "pending-geometry.json") {
        self.url = directory.appendingPathComponent(fileName)
    }

    public func load() -> [PendingGeometryEntry] {
        lock.lock(); defer { lock.unlock() }
        return unlockedLoad()
    }

    /// 锁内读-改-写（消费方只改自己那条；防阻塞期间读到的旧表覆盖新一轮恢复整写的 pending）
    public func update(_ transform: (inout [PendingGeometryEntry]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var entries = unlockedLoad()
        transform(&entries)
        unlockedSave(entries)
    }

    private func unlockedLoad() -> [PendingGeometryEntry] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([PendingGeometryEntry].self, from: data) else { return [] }
        return entries
    }

    public func save(_ entries: [PendingGeometryEntry]) {
        lock.lock(); defer { lock.unlock() }
        unlockedSave(entries)
    }

    private func unlockedSave(_ entries: [PendingGeometryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 移除单条并落盘（延迟应用成功/失败后一次性消费）
    public func remove(windowID: UInt32) {
        update { $0.removeAll { $0.windowID == windowID } }
    }
}

/// 延迟几何应用器：消费轮询判定窗口可写（所在 Space 活跃）时查 pending 补写 AX 几何
/// （此时窗口在可见 Space，AX 可达）。成功即消费；失败保留重试，达 maxAttempts 丢弃
///（实测 11-03 WeCom：切 Space 后首次补写 elementInvalid，一次性丢弃使窗停在缩过的高度）。
public final class DeferredGeometryApplier: @unchecked Sendable {
    /// 单窗补写尝试上限（含首次；消费轮询 2s 一次 ⇒ 约数秒内覆盖 AX 树滞后）
    public static let maxAttempts = 3
    /// 批量补写对「窗未进 AX 树」的快速重试轮数（不计失败额度）：切 Space 动画期间窗尚未进 AX 树，
    /// 等下一个 2s tick 用户看得见窗口迟迟才归位（11-03 09:29 实测）
    public static let elementInvalidQuickRetries = 4

    private let store: DeferredGeometryStore
    private let writer: WindowGeometryWriting
    private let displaysProvider: () -> [Displays.Info]
    private let log: LogWriting?
    /// 写后回读（nil = 读不到，不判定）：实测 11-03 WeChat 补写 AX 调用成功但实际高度仍缺 Dock 高度
    private let frameReader: @Sendable (UInt32) -> CGRect?
    /// 回读前等待（app 异步回弹 frame 的观察窗口）
    private let readBackDelay: TimeInterval
    /// 快速重试轮间隔
    private let elementInvalidRetryInterval: TimeInterval
    /// 回读容差（pt；终端类 app 按字符格对齐尺寸，小偏差不算失败）
    static let readBackTolerance: CGFloat = 10
    /// 独占代次源：AX 写期间管线开工（排空超时后照常开始）→ 本次结果过期，不消费不计失败
    private let session: SkyLightSession
    private let inFlight = LockedWindowIDs()

    public init(store: DeferredGeometryStore,
                writer: WindowGeometryWriting = AXGeometryWriter(),
                displaysProvider: @escaping () -> [Displays.Info] = Displays.active,
                log: LogWriting? = nil,
                frameReader: (@Sendable (UInt32) -> CGRect?)? = nil,
                readBackDelay: TimeInterval? = nil,
                elementInvalidRetryInterval: TimeInterval? = nil,
                session: SkyLightSession = SkyLightSession()) {
        self.store = store
        self.writer = writer
        self.displaysProvider = displaysProvider
        self.log = log
        self.session = session
        // 注入 reader（测试）不等待；生产 AX 回读前留 0.3s、elementInvalid 重试间隔 0.15s
        self.readBackDelay = readBackDelay ?? (frameReader == nil ? 0.3 : 0)
        self.elementInvalidRetryInterval = elementInvalidRetryInterval ?? (frameReader == nil ? 0.15 : 0)
        self.frameReader = frameReader ?? { wid in
            guard let element = AXFacade.findWindow(withWindowID: wid),
                  let origin = try? AXFacade.position(of: element),
                  let size = try? AXFacade.size(of: element) else { return nil }
            return CGRect(origin: origin, size: size)
        }
    }

    /// 单窗入口（单次尝试不快速重试）：有 pending 则应用一次。返回 true = 存在 pending（成功消费；失败未达上限则保留重试）。
    /// 读与回写分离：AX 写可阻塞数秒，期间新一轮恢复可能整写替换 pending（实测 11-03 第二轮
    /// WeCom 条目被旧表覆盖丢失）→ 回写只在锁内改「同一条」（同 wid 且同目标），不碰其余条目。
    @discardableResult
    public func applyIfPending(windowID: UInt32) -> Bool {
        attempt(windowID: windowID, deferAXMissing: false) != .noPending
    }

    /// 批量补写（消费轮询用）：每轮按 owner pid 建一次 AX 索引（同 app 多窗共用一次枚举），并发写；
    /// 窗未进 AX 树（elementInvalid / 非 AX）的条目隔 elementInvalidRetryInterval 重建索引再试，
    /// 不计失败额度，末轮仍缺才计一次失败。实测 11-04 01:52：逐窗反查 + 单条内重试让 Chrome 13 窗
    /// ≈ 40 次 AX 枚举在其主线程串行，整批 19s。每条开工前检查让出（恢复管线已开始则不再补写）。
    public func applyPending(windowIDs: [UInt32], shouldYield: () -> Bool) {
        var remaining = windowIDs
        var round = 0
        while !remaining.isEmpty, !shouldYield() {
            if round > 0 {
                if elementInvalidRetryInterval > 0 { Thread.sleep(forTimeInterval: elementInvalidRetryInterval) }
                if shouldYield() { return }  // 等待期间恢复管线开工：不再建索引与其争 AX
            }
            writer.prepare(windowIDs: remaining)
            let batch = remaining
            let isLastRound = round == Self.elementInvalidQuickRetries
            let missing = LockedWindowIDs()
            withoutActuallyEscaping(shouldYield) { yield in
                let yieldBox = UncheckedBox(yield)
                DispatchQueue.concurrentPerform(iterations: batch.count) { i in
                    if yieldBox.value() { return }
                    if attempt(windowID: batch[i], deferAXMissing: !isLastRound) == .axMissing {
                        missing.append(batch[i])
                    }
                }
            }
            remaining = missing.items
            round += 1
        }
    }

    func isApplying(windowID: UInt32) -> Bool {
        inFlight.contains(windowID)
    }

    private enum Attempt { case noPending, handled, axMissing }

    /// deferAXMissing = true：窗未进 AX 树不记失败，交调用方下一轮重试
    private func attempt(windowID: UInt32, deferAXMissing: Bool) -> Attempt {
        // 登记与取代次先于读 pending：管线据登记决定是否重申，晚登记会让它漏掉这次写
        inFlight.append(windowID)
        defer { inFlight.remove(windowID) }
        let generation = session.exclusiveGeneration
        if session.shouldYield { return .handled }
        guard let entry = store.load().first(where: { $0.windowID == windowID }) else { return .noPending }
        func isStale() -> Bool {
            guard session.exclusiveGeneration != generation else { return false }
            log?.write("[restore] deferred wid=\(windowID) result=stale detail=pipeline-started-during-apply")
            return true
        }
        func isSameEntry(_ e: PendingGeometryEntry) -> Bool {
            e.windowID == entry.windowID && e.displayUUID == entry.displayUUID
                && e.x == entry.x && e.y == entry.y && e.w == entry.w && e.h == entry.h
        }
        func consume() { store.update { $0.removeAll(where: isSameEntry) } }
        func retryOrDrop(_ detail: String) {
            let attempts = (entry.failedAttempts ?? 0) + 1
            let retry = attempts < Self.maxAttempts
            store.update { entries in
                guard let idx = entries.firstIndex(where: isSameEntry) else { return }
                if retry { entries[idx].failedAttempts = attempts } else { entries.remove(at: idx) }
            }
            log?.write("[restore] deferred wid=\(windowID) result=fail detail=\(detail) "
                + "attempt=\(attempts)/\(Self.maxAttempts)\(retry ? " retry" : " dropped")")
        }
        let display = displaysProvider().first { $0.uuid == entry.displayUUID }
            ?? displaysProvider().first
        guard let display, display.bounds.width > 0, display.bounds.height > 0 else {
            retryOrDrop("no-active-display")
            return .handled
        }
        func ratio(_ v: Double) -> CGFloat { CGFloat(LiveWindowLocator.clampRatio(v)) }
        let position = CGPoint(x: display.bounds.minX + ratio(entry.x) * display.bounds.width,
                               y: display.bounds.minY + ratio(entry.y) * display.bounds.height)
        let size = CGSize(width: ratio(entry.w) * display.bounds.width,
                          height: ratio(entry.h) * display.bounds.height)
        if isStale() { return .handled }
        do {
            do {
                try writer.apply(windowID: windowID, position: position, size: size)
            } catch {
                if isStale() { return .handled }
                throw error
            }
            if readBackDelay > 0 { Thread.sleep(forTimeInterval: readBackDelay) }
            if isStale() { return .handled }
            if let actual = frameReader(windowID) {
                let t = Self.readBackTolerance
                let fits = abs(actual.minX - position.x) <= t && abs(actual.minY - position.y) <= t
                    && abs(actual.width - size.width) <= t && abs(actual.height - size.height) <= t
                if !fits {
                    retryOrDrop("readback-mismatch want=\(Self.frameText(CGRect(origin: position, size: size))) "
                        + "got=\(Self.frameText(actual))")
                    return .handled
                }
            }
            consume()
            log?.write("[restore] deferred wid=\(windowID) result=ok detail=background-window-became-visible")
        } catch where deferAXMissing && Self.isAXMissing(error) {
            return .axMissing
        } catch {
            retryOrDrop("\(error)")
        }
        return .handled
    }

    /// 窗尚未进 AX 树：反查不到（elementInvalid）或所属 app 索引里没有（notAXWindow）
    static func isAXMissing(_ error: Error) -> Bool {
        if let error = error as? AXFacadeError, case .elementInvalid = error { return true }
        return (error as? RestoreEngineError) == .notAXWindow
    }

    private static func frameText(_ r: CGRect) -> String {
        "(x=\(Int(r.minX)),y=\(Int(r.minY)),w=\(Int(r.width)),h=\(Int(r.height)))"
    }
}

/// 并发安全的 wid 表：批量补写轮内收集「仍缺」的窗 / 在途补写登记（与管线 L1 线程并发读）
private final class LockedWindowIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [UInt32] = []
    var items: [UInt32] { lock.lock(); defer { lock.unlock() }; return _items }
    func append(_ wid: UInt32) { lock.lock(); _items.append(wid); lock.unlock() }
    func contains(_ wid: UInt32) -> Bool { lock.lock(); defer { lock.unlock() }; return _items.contains(wid) }
    func remove(_ wid: UInt32) {
        lock.lock(); defer { lock.unlock() }
        if let i = _items.firstIndex(of: wid) { _items.remove(at: i) }
    }
}

/// concurrentPerform 闭包内调用非 Sendable 的让出判定（判定只读 SkyLightSession.shouldYield，线程安全）
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
