import Foundation

// Schema.swift — 快照 schema v1（spec §7.3 逐字段）。票 11 拥有本文件。
// 命名约定：SnapshotSpace 是落盘持久化形态，与 Seams.SpaceEntry（票 12/13 运行时接缝）
// 刻意区分两个名字，避免「同一概念两种拼写」反向发生——持久化与运行时不混用。
// 字段口径（后续票 12/14 落盘/恢复沿用，勿擅改）：
//   - 全屏应用由 kind=fullscreen 的 Space 携带 fullscreenAppBundleID，不进 windows（spec §7.3）
//   - minimized 窗口照常记 spaceIndex（L4 恢复要用）；不存应用隐藏状态
//   - Space 按 index 引用（SLS Space ID 重启即变，不落盘）
//   - x/y/w/h 为所属屏 CGDisplayBounds 归一比例坐标（spec §7.2）

public let snapshotSchemaVersion = 1

public enum SnapshotSchemaError: Error, Equatable {
    /// 未知更高 version：拒用 + 日志，不写迁移（spec §7.3）
    case unsupportedVersion(found: Int, supported: Int)
    /// version < 1：schema 里不存在的版本，同样拒用
    case invalidVersion(found: Int)
}

public struct Snapshot: Codable, Equatable, Sendable {
    public var version: Int
    public var capturedAt: Date
    public var topology: [TopologyDisplay]
    public var spaces: [SnapshotSpace]
    public var windows: [SnapshotWindow]

    public init(capturedAt: Date, topology: [TopologyDisplay],
                spaces: [SnapshotSpace], windows: [SnapshotWindow]) {
        self.version = snapshotSchemaVersion
        self.capturedAt = capturedAt
        self.topology = topology
        self.spaces = spaces
        self.windows = windows
    }
}

public struct TopologyDisplay: Codable, Equatable, Sendable {
    public var uuid: String
    public var localizedName: String
    public var frame: SnapshotDisplayFrame
    public var orientation: Int
    public init(uuid: String, localizedName: String, frame: SnapshotDisplayFrame, orientation: Int) {
        self.uuid = uuid; self.localizedName = localizedName
        self.frame = frame; self.orientation = orientation
    }
}

/// 显示器 frame（spec §7.3 示例字段 x/y/w/h；绝对点坐标）
public struct SnapshotDisplayFrame: Codable, Equatable, Sendable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
}

public struct SnapshotSpace: Codable, Equatable, Sendable {
    public var displayUUID: String
    public var index: Int
    public var kind: SnapshotSpaceKind
    public var fullscreenAppBundleID: String?
    public init(displayUUID: String, index: Int, kind: SnapshotSpaceKind, fullscreenAppBundleID: String?) {
        self.displayUUID = displayUUID; self.index = index
        self.kind = kind; self.fullscreenAppBundleID = fullscreenAppBundleID
    }
}

/// Space 类型（spec §7.3：user | fullscreen）
public enum SnapshotSpaceKind: String, Codable, Equatable, Sendable {
    case user
    case fullscreen
}

public struct SnapshotWindow: Codable, Equatable, Sendable {
    public var bundleID: String
    public var title: String
    public var siblingIndex: Int
    public var displayUUID: String
    public var spaceIndex: Int
    public var x: Double, y: Double, w: Double, h: Double
    public var minimized: Bool
    public init(bundleID: String, title: String, siblingIndex: Int,
                displayUUID: String, spaceIndex: Int,
                x: Double, y: Double, w: Double, h: Double, minimized: Bool) {
        self.bundleID = bundleID; self.title = title; self.siblingIndex = siblingIndex
        self.displayUUID = displayUUID; self.spaceIndex = spaceIndex
        self.x = x; self.y = y; self.w = w; self.h = h; self.minimized = minimized
    }
}

extension Snapshot {
    /// 解码 + 版本守卫：先窥视 version，未知更高版本拒用不迁移（spec §7.3）。
    /// 缺 version / 字段损坏抛 DecodingError，由调用方按「解析失败」处理（存储层隔离）。
    public static func decode(from data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        struct VersionPeek: Decodable { let version: Int }
        let peek = try decoder.decode(VersionPeek.self, from: data)
        guard peek.version == snapshotSchemaVersion else {
            throw peek.version > snapshotSchemaVersion
                ? SnapshotSchemaError.unsupportedVersion(found: peek.version, supported: snapshotSchemaVersion)
                : SnapshotSchemaError.invalidVersion(found: peek.version)
        }
        return try decoder.decode(Snapshot.self, from: data)
    }

    /// 编码（schema 对外唯一编码口径：ISO8601 时间戳、pretty + 稳定键序，diff 友好）
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
