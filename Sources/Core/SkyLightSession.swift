import Foundation

// SkyLightSession.swift — 恢复/撤销管线对 SkyLight（SLS）与窗口几何的独占访问。
// 背景：SkyLight 非线程安全；poller 写盘 compose 的 SLS 读与管线并发，实测 managedSpaces 失败 →
// entries 空 → 整轮 L2 静默 skip（11-03 生产复现，DebugCLI 无 poller 复测即愈）。
// 语义：
//   - exclusive：恢复/撤销管线持有。多条管线（撤销 + 自动恢复可在不同队列同时开跑）串行；
//     进入前等在途 shared 排空，有上限（SLS 楔死时不无限阻塞，超时记一行照常开始）
//   - shared：后台读写方（poller 采样/写盘、pending 补写）。有独占持有或排队即返回 nil = 本轮跳过
//   - shouldYield：独占持有或排队中；长批次（补写）据此中途让出，加快排空
//   - slsRead：shared 之间不互斥（CG 采样不该排在秒级 AX 补写之后），只把各 shared 的 SLS 读段串行
//   - exclusiveGeneration：每次独占请求 +1；在途 AX 写返回后据此识别「期间管线已开工」= 结果过期

public final class SkyLightSession: @unchecked Sendable {
    private let cond = NSCondition()
    /// 持有中 + 排队中的独占请求数
    private var exclusiveRequests = 0
    private var exclusiveHeld = false
    private var sharedInFlight = 0
    private var generation: UInt64 = 0
    /// 与 cond 分开：SLS 读段阻塞不得拖住独占/shared 的状态判定
    private let slsReadLock = NSLock()
    private let drainTimeout: TimeInterval
    private let log: LogWriting?

    public init(drainTimeout: TimeInterval = 3, log: LogWriting? = nil) {
        self.drainTimeout = drainTimeout
        self.log = log
    }

    /// label 作日志前缀（restore / undo）
    public func exclusive<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        cond.lock()
        exclusiveRequests += 1
        generation &+= 1
        while exclusiveHeld { cond.wait() }
        exclusiveHeld = true
        let started = Date()
        let deadline = started.addingTimeInterval(drainTimeout)
        while sharedInFlight > 0, cond.wait(until: deadline) {}
        let leftover = sharedInFlight
        cond.unlock()
        if leftover > 0 {
            log?.write("[\(label)] action=exclusive-drain result=timeout detail=shared-in-flight=\(leftover) "
                + "waited=\(Int(Date().timeIntervalSince(started) * 1000))ms")
        }
        defer {
            cond.lock()
            exclusiveHeld = false
            exclusiveRequests -= 1
            cond.broadcast()
            cond.unlock()
        }
        return try body()
    }

    /// 无独占持有/排队时执行 body；否则返回 nil（不执行）
    public func shared<T>(_ body: () throws -> T) rethrows -> T? {
        cond.lock()
        guard exclusiveRequests == 0 else { cond.unlock(); return nil }
        sharedInFlight += 1
        cond.unlock()
        defer { cond.lock(); sharedInFlight -= 1; cond.broadcast(); cond.unlock() }
        return try body()
    }

    public var shouldYield: Bool {
        cond.lock(); defer { cond.unlock() }
        return exclusiveRequests > 0
    }

    /// 先读代次再查 shouldYield 为 false ⇒ 此后代次变化 = 有管线在本次操作期间开工
    public var exclusiveGeneration: UInt64 {
        cond.lock(); defer { cond.unlock() }
        return generation
    }

    /// shared 方的 SLS 读段（后台读方之间串行；AX 写与 CG 采样不要进来）
    public func slsRead<T>(_ body: () throws -> T) rethrows -> T {
        slsReadLock.lock(); defer { slsReadLock.unlock() }
        return try body()
    }

    /// 每次读走 slsRead 的 SpaceProviding（写盘 compose 用）
    public func serializingReads(of spaces: SpaceProviding) -> SpaceProviding {
        SLSReadSerializedSpaces(base: spaces, session: self)
    }
}

private struct SLSReadSerializedSpaces: SpaceProviding {
    let base: SpaceProviding
    let session: SkyLightSession

    func managedSpaces() throws -> [SpaceEntry] { try session.slsRead { try base.managedSpaces() } }
    func spaceIDsByWindowID() throws -> [UInt32: Int64] { try session.slsRead { try base.spaceIDsByWindowID() } }
}
