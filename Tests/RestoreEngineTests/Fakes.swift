@testable import Core  // @testable：测试需构造 Displays.Info（memberwise init 为 internal，Seams.swift 冻结不可改）
import CoreGraphics
import Foundation
import RestoreEngine
import SnapshotEngine
import XCTest

// Fakes — 票 14 测试注入桩（照 SnapshotEngineTests/Fakes 口径）。
// 单测全部经注入 fake 驱动（票面要求）；AX/SLS 活体路径留给票 17/19/20（本进程树无辅助功能授权）。

/// 桥接移窗 + Space 查询 fake：move 成功形态改写 byWindow（模拟归属真实变更，供幂等复跑用）
final class FakeBridge: SpaceBridge, @unchecked Sendable {
    let entries: [SpaceEntry]
    var byWindow: [UInt32: Int64]
    var bridgeAvailable: Bool
    /// 置非 nil = moveWindowsToSpace 抛该错误（异常路径注入）
    var moveError: Error?
    private(set) var moves: [(wids: [UInt32], spaceID: Int64)] = []

    init(entries: [SpaceEntry], byWindow: [UInt32: Int64], bridgeAvailable: Bool = true) {
        self.entries = entries
        self.byWindow = byWindow
        self.bridgeAvailable = bridgeAvailable
    }

    func managedSpaces() throws -> [SpaceEntry] { entries }
    func spaceIDsByWindowID() throws -> [UInt32: Int64] { byWindow }
    func isBridgeAvailable() -> Bool { bridgeAvailable }

    @discardableResult
    func moveWindowsToSpace(windowIDs wids: [UInt32], spaceID: Int64) throws -> Bool {
        moves.append((wids, spaceID))
        if let moveError { throw moveError }
        for w in wids { byWindow[w] = spaceID }
        return true
    }
}

/// AX 几何写 fake：记录调用；置 error 非 nil 模拟「AX 权限不足」等失败路径
final class FakeGeometry: WindowGeometryWriting, @unchecked Sendable {
    struct Call: Equatable {
        let windowID: UInt32
        let position: CGPoint
        let size: CGSize
    }
    private(set) var calls: [Call] = []
    var error: Error?

    func apply(windowID: UInt32, position: CGPoint, size: CGSize) throws {
        calls.append(Call(windowID: windowID, position: position, size: size))
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
            .appendingPathComponent("wlr-restoretests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// 测试本地错误（模拟「AX 权限不足」等写失败；引擎按任意 Error 抛出处理，不耦合具体类型）
struct FakeAXPermissionError: Error {}
