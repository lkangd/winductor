import Foundation
import XCTest
@testable import Core

// SkyLightSessionTests — 恢复/撤销管线独占 SkyLight 的并发语义。
// 接缝：SkyLightSession.exclusive / shared / shouldYield。
final class SkyLightSessionTests: XCTestCase {
    func testSharedRunsWhenIdleAndIsSkippedWhileExclusiveHeld() {
        let session = SkyLightSession()
        XCTAssertEqual(session.shared { 1 }, 1, "无独占：照常执行")
        session.exclusive("restore") {
            XCTAssertNil(session.shared { 1 }, "独占期间：跳过、不执行")
            XCTAssertTrue(session.shouldYield)
        }
        XCTAssertEqual(session.shared { 2 }, 2, "独占结束：恢复执行")
        XCTAssertFalse(session.shouldYield)
    }

    /// 撤销与自动恢复可在不同队列同时开跑：后到的独占等前一条结束，且前一条结束不提前放行 shared
    func testExclusiveCallsSerialize() {
        let session = SkyLightSession()
        let firstEntered = DispatchSemaphore(value: 0), releaseFirst = DispatchSemaphore(value: 0)
        let secondDone = expectation(description: "second exclusive finished")
        let order = LockedLog()
        DispatchQueue.global().async {
            session.exclusive("undo") {
                order.append("undo-start")
                firstEntered.signal()
                releaseFirst.wait()
                order.append("undo-end")
            }
        }
        firstEntered.wait()
        DispatchQueue.global().async {
            session.exclusive("restore") {
                order.append("restore-start")
                XCTAssertNil(session.shared { 1 }, "第二条独占期间 shared 仍被拦")
            }
            secondDone.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(order.items, ["undo-start"], "第一条未结束，第二条不得进入")
        releaseFirst.signal()
        wait(for: [secondDone], timeout: 2)
        XCTAssertEqual(order.items, ["undo-start", "undo-end", "restore-start"])
    }

    /// 管线开始时正在跑的 shared（写盘 compose / 补写批次）：等它结束再进独占；
    /// 等待期间 shouldYield 已置位（补写批次据此让出），新 shared 一律跳过
    func testExclusiveWaitsForInFlightSharedToDrain() {
        let session = SkyLightSession()
        let sharedEntered = DispatchSemaphore(value: 0), releaseShared = DispatchSemaphore(value: 0)
        let exclusiveDone = expectation(description: "exclusive finished")
        let order = LockedLog()
        DispatchQueue.global().async {
            _ = session.shared {
                sharedEntered.signal()
                releaseShared.wait()
                order.append("shared-end")
            }
        }
        sharedEntered.wait()
        DispatchQueue.global().async {
            session.exclusive("restore") { order.append("restore-start") }
            exclusiveDone.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(order.items, [], "在途 shared 未结束，独占不得进入")
        XCTAssertTrue(session.shouldYield, "等待独占期间即要求让出")
        XCTAssertNil(session.shared { 1 }, "等待独占期间新 shared 跳过")
        releaseShared.signal()
        wait(for: [exclusiveDone], timeout: 2)
        XCTAssertEqual(order.items, ["shared-end", "restore-start"])
    }

    /// 在途 shared 卡死（SLS 楔死）：等到上限即照常开始并记一行，不让管线无限阻塞
    func testExclusiveProceedsAfterDrainTimeoutAndLogs() {
        let log = LockedLog()
        let session = SkyLightSession(drainTimeout: 0.1, log: log)
        let sharedEntered = DispatchSemaphore(value: 0), releaseShared = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = session.shared {
                sharedEntered.signal()
                releaseShared.wait()
            }
        }
        sharedEntered.wait()
        var entered = false
        session.exclusive("undo") { entered = true }
        releaseShared.signal()
        XCTAssertTrue(entered, "超过排空上限仍进入独占")
        XCTAssertEqual(log.items.count, 1)
        XCTAssertTrue(log.items[0].hasPrefix("[undo] action=exclusive-drain result=timeout detail=shared-in-flight=1"),
                      "实际：\(log.items)")
    }

    /// 两个 shared（写盘 compose / pending 补写）可同时运行，但 SLS 读段互斥：后进者等前者读完
    func testConcurrentSharedSerializeOnlyTheirSLSReads() {
        let session = SkyLightSession()
        let firstReading = DispatchSemaphore(value: 0), releaseFirst = DispatchSemaphore(value: 0)
        let secondDone = expectation(description: "second shared finished")
        let order = LockedLog()
        DispatchQueue.global().async {
            _ = session.shared {
                session.slsRead {
                    firstReading.signal()
                    releaseFirst.wait()
                    order.append("first-read-end")
                }
            }
        }
        firstReading.wait()
        DispatchQueue.global().async {
            _ = session.shared {
                order.append("second-body")
                session.slsRead { order.append("second-read") }
            }
            secondDone.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(order.items, ["second-body"], "shared 体照常并发，SLS 读段等前者")
        releaseFirst.signal()
        wait(for: [secondDone], timeout: 2)
        XCTAssertEqual(order.items, ["second-body", "first-read-end", "second-read"])
    }

    func testSerializingReadsWrapsEverySpaceRead() {
        let session = SkyLightSession()
        let base = ReadLockProbe(session: session)
        let spaces = session.serializingReads(of: base)
        XCTAssertEqual(try spaces.managedSpaces(), [])
        XCTAssertEqual(try spaces.spaceIDsByWindowID(), [:])
        XCTAssertEqual(base.heldDuringReads.items, ["held", "held"])
    }

    /// 每次独占请求代次 +1（在途 AX 写返回后据此判过期）；shared 不改代次
    func testExclusiveGenerationAdvancesPerExclusiveRequest() {
        let session = SkyLightSession()
        let start = session.exclusiveGeneration
        _ = session.shared { 1 }
        XCTAssertEqual(session.exclusiveGeneration, start)
        session.exclusive("restore") {
            XCTAssertEqual(session.exclusiveGeneration, start + 1, "进入独占即已递增（排队期间也算）")
        }
        session.exclusive("undo") {}
        XCTAssertEqual(session.exclusiveGeneration, start + 2)
    }
}

/// 读时探测 SLS 读锁是否被持有：另一线程的 slsRead 0.1s 内进不来 = 本次读在锁内
private final class ReadLockProbe: SpaceProviding, @unchecked Sendable {
    let session: SkyLightSession
    let heldDuringReads = LockedLog()
    init(session: SkyLightSession) { self.session = session }

    private func probe() {
        let entered = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { self.session.slsRead { _ = entered.signal() } }
        let otherEntered = entered.wait(timeout: .now() + 0.1) == .success
        heldDuringReads.append(otherEntered ? "free" : "held")
    }

    func managedSpaces() throws -> [SpaceEntry] { probe(); return [] }
    func spaceIDsByWindowID() throws -> [UInt32: Int64] { probe(); return [:] }
}

private final class LockedLog: LogWriting, @unchecked Sendable {
    func write(_ line: String) { append(line) }
    private let lock = NSLock()
    private var _items: [String] = []
    var items: [String] { lock.lock(); defer { lock.unlock() }; return _items }
    func append(_ s: String) { lock.lock(); _items.append(s); lock.unlock() }
}
