@testable import Core  // @testable：测试需构造 Displays.Info（memberwise init 为 internal，Seams.swift 冻结不可改）
import CoreGraphics
import Foundation
import RestoreEngine
import SpaceAdapter  // SpaceLayer：降级阶梯层枚举（票 15 L3/L4 判定用）
import SnapshotEngine
import XCTest

// Fakes — 票 14 测试注入桩（照 SnapshotEngineTests/Fakes 口径）。
// 单测全部经注入 fake 驱动（票面要求）；AX/SLS 活体路径留给票 17/19/20（本进程树无辅助功能授权）。

/// 桥接移窗 + Space 查询 fake：move 成功形态改写 byWindow（模拟归属真实变更，供幂等复跑用）；
/// entries 可变（票 16 撤销两段式：全屏 Space 随恢复/Esc 创建销毁，需按阶段推进）
final class FakeBridge: SpaceBridge, @unchecked Sendable {
    var entries: [SpaceEntry]
    var byWindow: [UInt32: Int64]
    var bridgeAvailable: Bool
    /// 非 bridge 层（L3/L4）可用性注入；缺省 = 可用（票 15 降级阶梯）
    var layerAvailability: [SpaceLayer: Bool] = [:]
    /// 置非 nil = moveWindowsToSpace 抛该错误（异常路径注入）
    var moveError: Error?
    /// 置 true = moveWindowsToSpace 返回 false 且不改 byWindow（模拟 perform 后归属未变更 no-op）；
    /// 同 SpaceAdapter 口径：no-op 后 bridge 层失效，直到下一轮 beginRestoreRound
    var moveReturnsFalse = false
    /// 运行时 no-op 失效标记（beginRestoreRound 清除）
    private(set) var runtimeNoOp = false
    private(set) var roundsBegun = 0
    /// 置 true = tryMoveMinimized 返回 false（模拟最小化窗直移不可行，走 §6.5 回退路径）
    var minimizedDirectMoveFails = false
    /// 仅这些窗直移不可行（票 16：批量直移部分未迁移 → 逐窗回退）
    var minimizedDirectMoveFailIDs: Set<UInt32> = []
    /// 非 nil = activeSpaceIDs 返回该集合（活跃 Space 判定测试）
    var activeSpaces: Set<Int64>?
    /// ordered out 的窗（SLSWindowIsOrderedIn == false）；nil = 排列数据不可用（缺省，LiveWindowSet 降级）
    var orderedOut: Set<UInt32>?
    /// >0 = apply 前睡眠秒数（AX 写限时测试：睡 > 1.5s 触发 ax-apply-timeout）
    var applyDelay: TimeInterval?
    /// >0 = managedSpaces 前 N 次调用抛错（模拟 poller 并发 SLS 冲突：undo 快照与
    /// 管线 Space 清单两次读都可能失败，重试才成功）
    var managedSpacesFailures = 0
    /// 非 nil = 第 N 次 moveWindowsToSpace 后把 bridgeAvailable 翻 false（模拟桥接超时降级，实测缺陷）
    var degradeBridgeAfterMoves: Int?
    /// 每次桥接移动的阻塞钩子（模拟 WindowServer 楔死，测管线死线）
    var moveHook: (() -> Void)?
    private(set) var moveCalls = 0
    private(set) var moves: [(wids: [UInt32], spaceID: Int64)] = []
    private(set) var directMinimizedMoves: [(windowID: UInt32, spaceID: Int64)] = []
    /// 每次批量直移调用（票 16：同目标 Space 一次 perform）
    private(set) var directMinimizedBatches: [(wids: [UInt32], spaceID: Int64)] = []

    init(entries: [SpaceEntry], byWindow: [UInt32: Int64], bridgeAvailable: Bool = true) {
        self.entries = entries
        self.byWindow = byWindow
        self.bridgeAvailable = bridgeAvailable
    }

    func managedSpaces() throws -> [SpaceEntry] {
        if managedSpacesFailures > 0 {
            managedSpacesFailures -= 1
            throw SpaceAdapterError.slsFailed("concurrent poller")
        }
        return entries
    }
    func spaceIDsByWindowID() throws -> [UInt32: Int64] { byWindow }
    func orderedOutWindowIDs(among windowIDs: [UInt32]) -> Set<UInt32>? {
        orderedOut.map { $0.intersection(windowIDs) }
    }
    func activeSpaceIDs() throws -> Set<Int64> { activeSpaces ?? [] }
    func beginRestoreRound() { roundsBegun += 1; runtimeNoOp = false }

    /// 降级阶梯层可用性（spec §6.1/§10.2；bridge 沿用 bridgeAvailable 注入口）
    func isLayerAvailable(_ layer: SpaceLayer) -> Bool {
        if layer == .bridge { return bridgeAvailable && !runtimeNoOp }
        return layerAvailability[layer] ?? true
    }

    @discardableResult
    func moveWindowsToSpace(windowIDs wids: [UInt32], spaceID: Int64) throws -> Bool {
        moveCalls += 1
        moveHook?()
        if let n = degradeBridgeAfterMoves, moveCalls >= n { bridgeAvailable = false }
        moves.append((wids, spaceID))
        if let moveError { throw moveError }
        if moveReturnsFalse { runtimeNoOp = true; return false }
        for w in wids { byWindow[w] = spaceID }
        return true
    }

    /// L4 最小化窗批量直移尝试（票 15/16）：成功改写 byWindow；已在目标 Space 直接计入
    @discardableResult
    func tryMoveMinimized(windowIDs wids: [UInt32], spaceID: Int64) throws -> Set<UInt32> {
        directMinimizedBatches.append((wids, spaceID))
        var moved = Set<UInt32>()
        for wid in wids {
            directMinimizedMoves.append((wid, spaceID))
            if minimizedDirectMoveFails || minimizedDirectMoveFailIDs.contains(wid) { continue }
            byWindow[wid] = spaceID
            moved.insert(wid)
        }
        return moved
    }
}

/// AX 几何写 fake：记录调用；置 error 非 nil 模拟「AX 权限不足」等失败路径
final class FakeGeometry: WindowGeometryWriting, @unchecked Sendable {
    struct Call: Equatable {
        let windowID: UInt32
        let position: CGPoint
        let size: CGSize
    }
    // L1 8 路并发调 apply：calls 需加锁（无锁 append 在全量测试下偶发丢记录）
    private let callsLock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { callsLock.lock(); defer { callsLock.unlock() }; return _calls }
    private(set) var prepareCalls = 0
    var error: Error?
    /// >0 = apply 前睡眠秒数（AX 写限时测试：睡过 1.5s 上限触发 ax-apply-timeout）
    var applyDelay: TimeInterval?
    /// apply 期间执行的钩子（并发写入测试：模拟 AX 写阻塞期间新一轮恢复落盘 pending）
    var onApply: (() -> Void)?

    func prepare(windowIDs: [UInt32]) { prepareCalls += 1 }

    func apply(windowID: UInt32, position: CGPoint, size: CGSize) throws {
        if let d = applyDelay { Thread.sleep(forTimeInterval: d) }  // 限时测试：睡过 boundedApply 上限
        onApply?()
        callsLock.lock(); _calls.append(Call(windowID: windowID, position: position, size: size)); callsLock.unlock()
        if let error { throw error }
    }
}

/// 日志捕获（照 SnapshotEngineTests 的 LogSpy 口径）
final class LogSpy: LogWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
    func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
    }
}

/// 窗口枚举 fake（RestoreEngineTests 目标内自含；SnapshotEngineTests 的同名桩跨目标不可见）
final class FakeEnumerator: WindowEnumerating, @unchecked Sendable {
    let samples: [CGWindowSample]
    init(_ samples: [CGWindowSample]) { self.samples = samples }
    func sample() -> [CGWindowSample] { samples }
}

/// L3 全屏写 fake（票 15）：记录 (wid, value) 调用序列；置 error 模拟 AX 写失败
final class FakeFullScreen: WindowFullScreenWriting, @unchecked Sendable {
    private(set) var calls: [(windowID: UInt32, value: Bool)] = []
    var error: Error?

    func setFullScreen(windowID wid: UInt32, _ fullScreen: Bool) throws {
        calls.append((wid, fullScreen))
        if let error { throw error }
    }
}

/// L4 最小化写 fake（票 15）：记录 (wid, value) 调用序列；置 error 模拟 AX 写失败
final class FakeMinimize: WindowMinimizeWriting, @unchecked Sendable {
    private(set) var calls: [(windowID: UInt32, value: Bool)] = []
    var error: Error?

    func setMinimized(windowID wid: UInt32, _ minimized: Bool) throws {
        calls.append((wid, minimized))
        if let error { throw error }
    }
}

/// AX 探测桩（回滚快照组装 / 实况 minimized 判定用）
struct FakeAX: WindowAXProbing {
    var minimizedIDs: Set<UInt32> = []
    var callCount = 0
    func probe(pid: Int32, windowID: UInt32) -> WindowAXState {
        WindowAXState(minimized: minimizedIDs.contains(windowID), fullScreen: false)
    }
}

// MARK: - 场景构造助手

enum World {
    /// 标准双屏拓扑：A (0,0,1000,1000)、B (2000,0,1000,1000)，旋转角由用例指定
    static func displays(aOrientation: Int = 0, bOrientation: Int = 0) -> [Displays.Info] {
        [Displays.Info(id: 1, bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), uuid: "A-uuid"),
         Displays.Info(id: 2, bounds: CGRect(x: 2000, y: 0, width: 1000, height: 1000), uuid: "B-uuid")]
    }

    static func topologyEntry(uuid: String, name: String, orientation: Int,
                              x: Double, y: Double, w: Double, h: Double) -> TopologyDisplay {
        TopologyDisplay(uuid: uuid, localizedName: name,
                        frame: SnapshotDisplayFrame(x: x, y: y, w: w, h: h), orientation: orientation)
    }

    static func userSpace(_ displayUUID: String, index: Int) -> SnapshotSpace {
        SnapshotSpace(displayUUID: displayUUID, index: index, kind: .user, fullscreenAppBundleID: nil)
    }

    static func entry(_ displayUUID: String, index: Int, id: Int64, kind: Int = 0) -> SpaceEntry {
        SpaceEntry(spaceID: id, displayUUID: displayUUID, index: index, kind: kind)
    }

    static func snapshotWindow(bundleID: String, title: String, sibling: Int,
                               display: String, space: Int,
                               x: Double, y: Double, w: Double, h: Double,
                               minimized: Bool = false) -> SnapshotWindow {
        SnapshotWindow(bundleID: bundleID, title: title, siblingIndex: sibling,
                       displayUUID: display, spaceIndex: space,
                       x: x, y: y, w: w, h: h, minimized: minimized)
    }

    /// 存活窗口采样：ratio 相对 origin 所在屏的归一坐标 → 绝对 bounds
    static func sample(wid: UInt32, pid: Int32 = 100, bundleID: String, title: String?,
                       displayOrigin: CGPoint, displaySize: CGSize,
                       x: Double, y: Double, w: Double, h: Double,
                       onscreen: Bool = true) -> CGWindowSample {
        CGWindowSample(windowID: wid, pid: pid, bundleID: bundleID, title: title,
                       bounds: CGRect(x: displayOrigin.x + CGFloat(x) * displaySize.width,
                                      y: displayOrigin.y + CGFloat(y) * displaySize.height,
                                      width: CGFloat(w) * displaySize.width,
                                      height: CGFloat(h) * displaySize.height),
                       isOnscreen: onscreen)
    }

    /// 旋转角注入（ Displays.rotation 真实现会读真实显示器，单测必须注入定值）
    static func rotationProvider(_ map: [CGDirectDisplayID: Int]) -> (CGDirectDisplayID) -> Int {
        { map[$0] ?? 0 }
    }
}

extension XCTestCase {
    /// 隔离临时目录（每个用例独享，用完清理）
    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("winductor-restoretests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// 测试本地错误（模拟「AX 权限不足」等写失败；引擎按任意 Error 抛出处理，不耦合具体类型）
struct FakeAXPermissionError: Error {}
