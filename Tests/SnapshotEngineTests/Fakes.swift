@testable import Core  // @testable：测试需构造 Displays.Info（memberwise init 为 internal，Seams.swift 冻结不可改）
import Foundation
import SnapshotEngine
import XCTest

// Fakes — 票 12 测试注入桩：CG 枚举、AX 读取、Space 提供方、日志捕获。
// 真实显示器/窗口操作只读；单测全部经注入 fake 驱动（票面「无法真实验证的部分用注入 fake 覆盖」）。

/// 依次返回预置采样序列（超出后停留末位）；记录调用次数
final class FakeEnumerator: WindowEnumerating, @unchecked Sendable {
    private let lock = NSLock()
    private let samples: [[CGWindowSample]]
    private var index = 0
    private(set) var callCount = 0

    init(_ samples: [CGWindowSample]...) {
        self.samples = samples.isEmpty ? [[]] : samples
    }

    /// 数组形式（采样序列程序化构造时用）
    init(_ samples: [[CGWindowSample]]) {
        self.samples = samples.isEmpty ? [[]] : samples
    }

    func sample() -> [CGWindowSample] {
        lock.lock(); defer { lock.unlock() }
        callCount += 1
        let s = samples[min(index, samples.count - 1)]
        index += 1
        return s
    }
}

/// AX 读取桩：计数调用（AX 按需探测的断言用）；minimized/fullScreen 按窗口 ID 预置
final class FakeAXProber: WindowAXProbing, @unchecked Sendable {
    private let lock = NSLock()
    private let minimizedIDs: Set<UInt32>
    private let fullscreenIDs: Set<UInt32>
    private(set) var callCount = 0

    init(minimizedIDs: Set<UInt32> = [], fullscreenIDs: Set<UInt32> = []) {
        self.minimizedIDs = minimizedIDs
        self.fullscreenIDs = fullscreenIDs
    }

    func probe(pid: Int32, windowID: UInt32) -> WindowAXState {
        lock.lock(); defer { lock.unlock() }
        callCount += 1
        return WindowAXState(minimized: minimizedIDs.contains(windowID),
                             fullScreen: fullscreenIDs.contains(windowID))
    }
}

/// SpaceProviding fake（Core/Seams 冻结接缝的测试实现）
final class FakeSpaces: SpaceProviding, @unchecked Sendable {
    let entries: [SpaceEntry]
    let byWindow: [UInt32: Int64]

    init(entries: [SpaceEntry], byWindow: [UInt32: Int64]) {
        self.entries = entries
        self.byWindow = byWindow
    }

    func managedSpaces() throws -> [SpaceEntry] { entries }
    func spaceIDsByWindowID() throws -> [UInt32: Int64] { byWindow }
}

/// 延迟几何端口 fake：预置覆盖
final class FakeDeferredGeometry: DeferredGeometryPort, @unchecked Sendable {
    var overrides: [UInt32: WindowGeometryOverride] = [:]
    func geometryOverrides() -> [UInt32: WindowGeometryOverride] { overrides }
}

/// 日志捕获（照 CoreTests 的 LogSpy 口径）
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

extension XCTestCase {
    /// 单屏 fake 拓扑：uuid 前缀 + 1000×1000
    func fakeDisplay(_ uuid: String, x: Double = 0, y: Double = 0,
                     w: Double = 1000, h: Double = 1000) -> Displays.Info {
        Displays.Info(id: 1, bounds: CGRect(x: x, y: y, width: w, height: h), uuid: uuid)
    }

    /// 隔离临时目录（每个用例独享，用完清理）
    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("winductor-enginetests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
