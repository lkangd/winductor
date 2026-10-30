import Core
import CoreGraphics
import Foundation
import SnapshotEngine
import SpaceAdapter

// Simulation.swift — simulate-restore 干跑接缝（retro 优化：多屏验收免硬件可验）。
// 用 fixture JSON 描述「显示器 + Space + 存活窗」，注入恢复管线的全部接缝后跑真实
// RestoreEngine.restore：保守匹配、L2 桥接、L1 摆位、降级阶梯判定全部走生产代码，
// 只有「动手」被替换为记录。回滚快照照 §7.4 照写，但落指定临时目录，不碰真实快照库。
// fixture 口径：窗口坐标为全局绝对点（同 CGWindowBounds）；比例归一由管线自己算。

// MARK: - fixture 模型

public struct SimulatedTopologyFixture: Codable, Equatable, Sendable {
    public struct Display: Codable, Equatable, Sendable {
        public var uuid: String
        public var x: Double, y: Double, w: Double, h: Double
        /// 捕获旋转角（0/90/180/270，spec §7.2）；缺省 0
        public var rotation: Int

        public init(uuid: String, x: Double, y: Double, w: Double, h: Double, rotation: Int = 0) {
            self.uuid = uuid; self.x = x; self.y = y; self.w = w; self.h = h
            self.rotation = rotation
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = try c.decode(String.self, forKey: .uuid)
            x = try c.decode(Double.self, forKey: .x)
            y = try c.decode(Double.self, forKey: .y)
            w = try c.decode(Double.self, forKey: .w)
            h = try c.decode(Double.self, forKey: .h)
            rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        }
    }

    public struct Space: Codable, Equatable, Sendable {
        public var displayUUID: String
        public var spaceID: Int64
        public var index: Int
        /// 0 = 用户桌面，4 = 全屏（spec §5.1）
        public var kind: Int

        public init(displayUUID: String, spaceID: Int64, index: Int, kind: Int) {
            self.displayUUID = displayUUID; self.spaceID = spaceID
            self.index = index; self.kind = kind
        }
    }

    public struct Window: Codable, Equatable, Sendable {
        public var windowID: UInt32
        public var pid: Int32
        public var bundleID: String
        /// kCGWindowName 口径；nil = 屏幕录制权限缺失形态
        public var title: String?
        /// 全局绝对点 bounds（同 kCGWindowBounds）
        public var x: Double, y: Double, w: Double, h: Double
        /// kCGWindowIsOnscreen；缺省 true
        public var onscreen: Bool
        /// AX 最小化态（离屏窗探测用）；缺省 false
        public var minimized: Bool
        /// AXFullScreen 态；缺省 false
        public var fullScreen: Bool
        /// 当前归属 Space（spaceIDsByWindowID 口径）
        public var spaceID: Int64

        public init(windowID: UInt32, pid: Int32, bundleID: String, title: String? = nil,
                    x: Double, y: Double, w: Double, h: Double,
                    onscreen: Bool = true, minimized: Bool = false, fullScreen: Bool = false,
                    spaceID: Int64) {
            self.windowID = windowID; self.pid = pid; self.bundleID = bundleID; self.title = title
            self.x = x; self.y = y; self.w = w; self.h = h
            self.onscreen = onscreen; self.minimized = minimized; self.fullScreen = fullScreen
            self.spaceID = spaceID
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            windowID = try c.decode(UInt32.self, forKey: .windowID)
            pid = try c.decode(Int32.self, forKey: .pid)
            bundleID = try c.decode(String.self, forKey: .bundleID)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            x = try c.decode(Double.self, forKey: .x)
            y = try c.decode(Double.self, forKey: .y)
            w = try c.decode(Double.self, forKey: .w)
            h = try c.decode(Double.self, forKey: .h)
            onscreen = try c.decodeIfPresent(Bool.self, forKey: .onscreen) ?? true
            minimized = try c.decodeIfPresent(Bool.self, forKey: .minimized) ?? false
            fullScreen = try c.decodeIfPresent(Bool.self, forKey: .fullScreen) ?? false
            spaceID = try c.decode(Int64.self, forKey: .spaceID)
        }
    }

    public struct Layers: Codable, Equatable, Sendable {
        public var bridge: Bool
        public var fullscreen: Bool
        public var minimized: Bool

        public init(bridge: Bool = true, fullscreen: Bool = true, minimized: Bool = true) {
            self.bridge = bridge; self.fullscreen = fullscreen; self.minimized = minimized
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bridge = try c.decodeIfPresent(Bool.self, forKey: .bridge) ?? true
            fullscreen = try c.decodeIfPresent(Bool.self, forKey: .fullscreen) ?? true
            minimized = try c.decodeIfPresent(Bool.self, forKey: .minimized) ?? true
        }
    }

    public var displays: [Display]
    public var spaces: [Space]
    public var windows: [Window]
    public var layers: Layers

    public init(displays: [Display], spaces: [Space], windows: [Window], layers: Layers = Layers()) {
        self.displays = displays; self.spaces = spaces; self.windows = windows; self.layers = layers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displays = try c.decode([Display].self, forKey: .displays)
        spaces = try c.decode([Space].self, forKey: .spaces)
        windows = try c.decode([Window].self, forKey: .windows)
        layers = try c.decodeIfPresent(Layers.self, forKey: .layers) ?? Layers()
    }
}

// MARK: - 动作记录

public struct SimulatedBridgeMove: Equatable, Sendable {
    public let windowIDs: [UInt32]
    public let spaceID: Int64
}

public struct SimulatedGeometryWrite: Equatable, Sendable {
    public let windowID: UInt32
    public let position: CGPoint
    public let size: CGSize
}

public struct SimulatedToggleWrite: Equatable, Sendable {
    public let windowID: UInt32
    public let value: Bool
}

/// 干跑记录：管线「本要做什么」的全部动作（真实恢复里这些会写 AX/SLS）
public struct SimulatedActionLog: Equatable, Sendable {
    public var bridgeMoves: [SimulatedBridgeMove] = []
    public var minimizedDirectMoves: [SimulatedBridgeMove] = []
    public var geometryWrites: [SimulatedGeometryWrite] = []
    public var fullscreenSets: [SimulatedToggleWrite] = []
    public var minimizeSets: [SimulatedToggleWrite] = []
}

// MARK: - 注入桩（单类实现全部写接缝；记录替代动手）

final class SimulatedSeams: SpaceBridge, @unchecked Sendable {
    private let fixture: SimulatedTopologyFixture
    private let lock = NSLock()
    private(set) var actionLog = SimulatedActionLog()
    /// 合成 displayID（fixture 下标 +1）→ frame/uuid/rotation，契约排序（先 x 后 y）只影响 Displays.Info 数组序
    private let displayByID: [CGDirectDisplayID: SimulatedTopologyFixture.Display]

    init(fixture: SimulatedTopologyFixture) {
        self.fixture = fixture
        var byID: [CGDirectDisplayID: SimulatedTopologyFixture.Display] = [:]
        for (i, d) in fixture.displays.enumerated() { byID[CGDirectDisplayID(i + 1)] = d }
        self.displayByID = byID
    }

    /// Displays.active 契约口径：按 origin.x（再 origin.y）排序
    func displays() -> [Displays.Info] {
        fixture.displays.enumerated().map { i, d in
            Displays.Info(id: CGDirectDisplayID(i + 1),
                          bounds: CGRect(x: d.x, y: d.y, width: d.w, height: d.h),
                          uuid: d.uuid)
        }
        .sorted { ($0.bounds.minX, $0.bounds.minY) < ($1.bounds.minX, $1.bounds.minY) }
    }

    func rotation(for id: CGDirectDisplayID) -> Int {
        displayByID[id]?.rotation ?? 0
    }

    private func record<T>(_ keyPath: WritableKeyPath<SimulatedActionLog, T>, _ value: T) {
        lock.lock(); defer { lock.unlock() }
        actionLog[keyPath: keyPath] = value
    }
}

extension SimulatedSeams: SpaceProviding {
    public func managedSpaces() throws -> [SpaceEntry] {
        fixture.spaces.map { SpaceEntry(spaceID: $0.spaceID, displayUUID: $0.displayUUID,
                                        index: $0.index, kind: $0.kind) }
    }

    public func spaceIDsByWindowID() throws -> [UInt32: Int64] {
        var out = [UInt32: Int64]()
        for w in fixture.windows { out[w.windowID] = w.spaceID }
        return out
    }
}

extension SimulatedSeams {
    public func isLayerAvailable(_ layer: SpaceLayer) -> Bool {
        switch layer {
        case .bridge: return fixture.layers.bridge
        case .fullscreen: return fixture.layers.fullscreen
        case .minimized: return fixture.layers.minimized
        }
    }

    @discardableResult
    public func moveWindowsToSpace(windowIDs wids: [UInt32], spaceID: Int64) throws -> Bool {
        record(\.bridgeMoves, actionLog.bridgeMoves + [SimulatedBridgeMove(windowIDs: wids, spaceID: spaceID)])
        return true
    }

    @discardableResult
    public func tryMoveMinimized(windowID wid: UInt32, spaceID: Int64) throws -> Bool {
        record(\.minimizedDirectMoves,
               actionLog.minimizedDirectMoves + [SimulatedBridgeMove(windowIDs: [wid], spaceID: spaceID)])
        return true
    }
}

extension SimulatedSeams: WindowEnumerating {
    public func sample() -> [CGWindowSample] {
        fixture.windows.map {
            CGWindowSample(windowID: $0.windowID, pid: $0.pid, bundleID: $0.bundleID,
                           title: $0.title,
                           bounds: CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h),
                           isOnscreen: $0.onscreen)
        }
    }
}

extension SimulatedSeams: WindowAXProbing {
    public func probe(pid: Int32, windowID: UInt32) -> WindowAXState {
        let w = fixture.windows.first { $0.windowID == windowID }
        return WindowAXState(minimized: w?.minimized ?? false, fullScreen: w?.fullScreen ?? false)
    }
}

extension SimulatedSeams: WindowGeometryWriting {
    public func apply(windowID: UInt32, position: CGPoint, size: CGSize) throws {
        record(\.geometryWrites,
               actionLog.geometryWrites + [SimulatedGeometryWrite(windowID: windowID,
                                                                  position: position, size: size)])
    }
}

extension SimulatedSeams: WindowFullScreenWriting {
    public func setFullScreen(windowID wid: UInt32, _ fullScreen: Bool) throws {
        record(\.fullscreenSets, actionLog.fullscreenSets + [SimulatedToggleWrite(windowID: wid, value: fullScreen)])
    }
}

extension SimulatedSeams: WindowMinimizeWriting {
    public func setMinimized(windowID wid: UInt32, _ minimized: Bool) throws {
        record(\.minimizeSets, actionLog.minimizeSets + [SimulatedToggleWrite(windowID: wid, value: minimized)])
    }
}

// MARK: - 干跑入口

public enum SimulatedRestore {
    /// 用 fixture 顶替实况跑一轮真实恢复管线；回滚快照照写但落 storeDirectory（调用方给临时目录）。
    /// 返回管线报告 + 「本要做什么」的动作记录。抛错口径与 restore 相同（无显示器/回滚快照写失败）。
    public static func run(snapshot: Snapshot,
                           fixture: SimulatedTopologyFixture,
                           log: LogWriting?,
                           storeDirectory: URL) throws -> (RestoreReport, SimulatedActionLog) {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let seams = SimulatedSeams(fixture: fixture)
        let engine = RestoreEngine(
            store: SnapshotStore(directory: storeDirectory, log: log),
            spaces: seams,
            enumerator: seams,
            ax: seams,
            geometry: seams,
            fullscreen: seams,
            minimize: seams,
            fullscreenSettleSeconds: 0,
            displaysProvider: { seams.displays() },
            rotationProvider: { seams.rotation(for: $0) },
            log: log)
        let report = try engine.restore(snapshot: snapshot)
        return (report, seams.actionLog)
    }
}
