import CoreGraphics
import Darwin
import Foundation

// Seams.swift — 模块间接缝（由编排者冻结）。
// ⚠️ 本文件的公开签名是并行票之间的契约：
//   - SpaceProviding / SpaceEntry：SnapshotEngine（票 12）消费、SpaceAdapter（票 13）实现。
//   - Displays：公开 API 的显示器枚举/几何/稳定 UUID（spec §5.1，port 自 05 spike 实测写法）。
// 修改签名会让并行票合并冲突——除非编排者要求，禁止改动。实现内部可修 bug。

/// 受管 Space 的描述（快照 schema 以 displayUUID + index 引用 Space，spec §7.3）。
public struct SpaceEntry: Equatable, Sendable {
    /// SLS space id64（== ManagedSpaceID，spec §5.1 实测恒等）
    public let spaceID: Int64
    /// 所属显示器稳定 UUID
    public let displayUUID: String
    /// 每屏 1 起的顺序号（快照 schema `spaceIndex` 引用它）
    public let index: Int
    /// 0 = 用户桌面，4 = 全屏（spec §5.1 实测）
    public let kind: Int

    public init(spaceID: Int64, displayUUID: String, index: Int, kind: Int) {
        self.spaceID = spaceID
        self.displayUUID = displayUUID
        self.index = index
        self.kind = kind
    }
}

/// Space 信息源接缝：SnapshotEngine 借此把窗口落到 spaceIndex，SpaceAdapter 提供 SLS 实现。
public protocol SpaceProviding: Sendable {
    /// 全部受管 Space（含各屏全屏 Space），等价 SLSCopyManagedDisplaySpaces 的展开
    func managedSpaces() throws -> [SpaceEntry]

    /// CGWindowID（kCGWindowNumber）→ spaceID；最小化窗口报原 Space（spec §5.1 实测）
    func spaceIDsByWindowID() throws -> [UInt32: Int64]
}

/// 公开 API：显示器枚举、几何、旋转与稳定 UUID。
/// UUID 依赖 CGDisplayCreateUUIDFromDisplayID（dlsym，见 spike；spec §5.1 半边缘能力，实测稳定）。
public enum Displays: Sendable {
    public struct Info: Equatable, Sendable {
        public let id: CGDirectDisplayID
        public let bounds: CGRect
        public let uuid: String?
    }

    private typealias DisplayUUIDFn = @convention(c) (UInt32) -> CFUUID?

    private static let uuidFn: DisplayUUIDFn? = {
        let libs = [
            "/System/Library/Frameworks/ColorSync.framework/ColorSync",
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            "",
        ]
        for lib in libs {
            let h = lib.isEmpty ? dlopen(nil, RTLD_LAZY) : dlopen(lib, RTLD_LAZY)
            guard let hh = h, let p = dlsym(hh, "CGDisplayCreateUUIDFromDisplayID") else { continue }
            return unsafeBitCast(p, to: DisplayUUIDFn.self)
        }
        return nil
    }()

    /// 全部活动显示器，按 origin.x（再 origin.y）从左到右排序（与 spike `displays()` 一致）。
    public static func active() -> [Info] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        return (0..<Int(count)).map { i -> Info in
            let id = ids[i]
            return Info(id: id, bounds: CGDisplayBounds(id), uuid: uuid(for: id))
        }
        .sorted { ($0.bounds.minX, $0.bounds.minY) < ($1.bounds.minX, $1.bounds.minY) }
    }

    /// 稳定显示器 UUID（SLS Display Identifier 同值，spec §5.1）
    public static func uuid(for id: CGDirectDisplayID) -> String? {
        guard let f = uuidFn, let cfuuid = f(id) else { return nil }
        return CFUUIDCreateString(nil, cfuuid) as String?
    }

    /// 所属屏整块 CGDisplayBounds（非可见 frame；比例坐标归一基准，spec §7.2）
    public static func bounds(for id: CGDirectDisplayID) -> CGRect {
        CGDisplayBounds(id)
    }

    /// 捕获旋转角（0/90/180/270，spec §7.2）
    public static func rotation(for id: CGDirectDisplayID) -> Int {
        Int(CGDisplayRotation(id))
    }
}
