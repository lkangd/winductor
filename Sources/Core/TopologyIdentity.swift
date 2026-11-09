import CoreGraphics
import CryptoKit
import Foundation

// TopologyIdentity.swift — 拓扑身份（spec §3.1/§3.2/§3.3，ADR 0002）。纯函数，无 IO。

/// 拓扑计算的输入：一块活动屏的当前状态（frame 为 CGDisplayBounds 口径的全局 point 坐标）
public struct TopologyScreen: Equatable, Sendable {
    public let uuid: String
    public let name: String
    public let frame: CGRect
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// 旋转角（0/90/180/270）
    public let rotation: Int
    /// 是否处于镜像集合
    public let isMirrored: Bool
    /// 是否内置屏（CGDisplayIsBuiltin；nil = 未读取）。只进展示数据（排列图刘海），不参与身份
    public let isBuiltin: Bool?

    public init(uuid: String, name: String, frame: CGRect, pixelWidth: Int, pixelHeight: Int,
                rotation: Int, isMirrored: Bool, isBuiltin: Bool? = nil) {
        self.uuid = uuid; self.name = name; self.frame = frame
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.rotation = rotation; self.isMirrored = isMirrored; self.isBuiltin = isBuiltin
    }
}

/// 屏的一条边（相对该屏：邻居在它的 左/右/上/下）
public enum TopologySide: String, CaseIterable, Sendable {
    case left, right, above, below
}

/// 拓扑身份：规范化描述 + 由它唯一决定的稳定拓扑键。
/// 身份要素（spec §3.1）：UUID 集合 + 邻接排列（每屏每条边上贴合的邻居，按沿边先后排列）+ 各屏旋转；
/// 分辨率、沿边偏移量、主屏（坐标原点）不参与——只用「贴合与否」与「沿边先后」，不用坐标值本身。
public struct TopologyIdentity: Hashable, Sendable {
    /// 贴合容差（point）：吸收点坐标取整误差；沿边重叠也须超过它，仅角点相触不算邻接
    public static let adjacencyTolerance: CGFloat = 2

    /// 人类可读的规范化描述（与枚举顺序无关；同目录存放供排查）
    public let canonicalDescription: String
    /// 稳定拓扑键：规范化描述的哈希（32 位小写十六进制），可直接作文件/目录名
    public let key: String
    /// 屏幕 UUID 集合（字典序）
    public let displayUUIDs: [String]

    init(screens: [TopologyScreen]) {
        let sorted = screens.sorted { $0.uuid < $1.uuid }
        displayUUIDs = sorted.map(\.uuid)
        let lines = sorted.map { s -> String in
            var parts = [s.uuid, "rot=\(Self.normalizedRotation(s.rotation))"]
            for side in TopologySide.allCases {
                let neighbors = Self.neighbors(of: s, on: side, among: sorted)
                if !neighbors.isEmpty { parts.append("\(side.rawValue)=[\(neighbors.joined(separator: ","))]") }
            }
            return parts.joined(separator: " ")
        }
        canonicalDescription = (["topology v1"] + lines).joined(separator: "\n")
        key = Self.hash(canonicalDescription)
    }

    /// 贴在 screen 某条边上的邻居 UUID，按沿边先后（左右边自上而下、上下边自左而右）
    static func neighbors(of screen: TopologyScreen, on side: TopologySide,
                          among all: [TopologyScreen]) -> [String] {
        let a = screen.frame, tol = adjacencyTolerance
        return all.filter { other in
            guard other.uuid != screen.uuid else { return false }
            let b = other.frame
            switch side {
            case .left: return abs(b.maxX - a.minX) <= tol && overlap(a.minY, a.maxY, b.minY, b.maxY) > tol
            case .right: return abs(b.minX - a.maxX) <= tol && overlap(a.minY, a.maxY, b.minY, b.maxY) > tol
            case .above: return abs(b.maxY - a.minY) <= tol && overlap(a.minX, a.maxX, b.minX, b.maxX) > tol
            case .below: return abs(b.minY - a.maxY) <= tol && overlap(a.minX, a.maxX, b.minX, b.maxX) > tol
            }
        }
        .sorted { side == .left || side == .right ? $0.frame.midY < $1.frame.midY : $0.frame.midX < $1.frame.midX }
        .map(\.uuid)
    }

    private static func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat {
        min(a1, b1) - max(a0, b0)
    }

    /// 旋转归一到 0/90/180/270
    static func normalizedRotation(_ degrees: Int) -> Int {
        let r = ((degrees % 360) + 360) % 360
        return (r + 45) / 90 % 4 * 90
    }

    /// SHA-256 前 128 bit 的小写十六进制（定长 32，文件名安全）
    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// 拓扑展示数据（spec §3.2）：供排列图与默认别名，随保存预设刷新，不参与身份
public struct TopologyDisplayInfo: Codable, Equatable, Sendable {
    public var uuid: String
    public var name: String
    /// 最近一次见到的 frame（全局 point 坐标）
    public var frame: SnapshotDisplayFrame
    /// 分辨率（像素）
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var rotation: Int
    /// 是否内置屏（ui-refactor 票 04：排列图画刘海）。保存预设时随实况填入；旧数据无此键 → nil（按非内置画，不画刘海）。
    /// 与其余展示数据一样不参与拓扑身份（身份只由 TopologyIdentity 从 UUID/邻接/旋转算出）
    public var isBuiltin: Bool?

    public init(uuid: String, name: String, frame: SnapshotDisplayFrame,
                pixelWidth: Int, pixelHeight: Int, rotation: Int, isBuiltin: Bool? = nil) {
        self.uuid = uuid; self.name = name; self.frame = frame
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.rotation = rotation
        self.isBuiltin = isBuiltin
    }
}

/// 一次观测的拓扑：身份 + 展示数据 + 镜像标记
public struct ObservedTopology: Sendable {
    public let identity: TopologyIdentity
    /// 展示数据，按从左到右（再自上而下）排列
    public let displays: [TopologyDisplayInfo]
    /// 任一屏处于镜像集合（spec §3.3：此时不弹提示、不自动恢复、禁止保存）
    public let isMirrored: Bool

    public init(screens: [TopologyScreen]) {
        identity = TopologyIdentity(screens: screens)
        displays = screens
            .sorted { ($0.frame.minX, $0.frame.minY, $0.uuid) < ($1.frame.minX, $1.frame.minY, $1.uuid) }
            .map {
                TopologyDisplayInfo(
                    uuid: $0.uuid, name: $0.name,
                    frame: SnapshotDisplayFrame(x: $0.frame.minX, y: $0.frame.minY,
                                                w: $0.frame.width, h: $0.frame.height),
                    pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight,
                    rotation: TopologyIdentity.normalizedRotation($0.rotation),
                    isBuiltin: $0.isBuiltin)
            }
        isMirrored = screens.contains(where: \.isMirrored)
    }
}
