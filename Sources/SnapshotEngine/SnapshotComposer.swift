import Core
import CoreGraphics
import Foundation

// SnapshotComposer.swift — 快照内容映射（spec §7.3）。仅在一次性拍快照路径执行（SnapshotEngine.capture）。
// 口径：
//   - 入快照的窗口集合 + minimized：Core.LiveWindowSet（与恢复实况、VerifyCLI 同一份判定：无 Space 归属/
//     多 Space 粘性窗、ordered out 且非最小化的隐藏窗不入；ordered out 最小化窗记 minimized）
//   - 窗口→displayUUID + 比例几何：Core.LiveWindowLocator（Space 所属屏优先，无 Space 按 frame 兜底；
//     归属屏无稳定 UUID 的窗不入快照）
//   - 窗口→spaceIndex：Core/Seams 的 SpaceProviding 接缝（spaceIDsByWindowID → SpaceEntry.index）；
//     Space 数据不可用时降级：spaces=[]、spaceIndex=1（几何层仍可恢复，spec §8.5 降级阶梯）
//   - 所在 Space kind == 全屏的窗不进 windows，改记到该 Space 的 fullscreenAppBundleID
//     （spec §7.3：全屏应用由 Space 携带，不进 windows；SLS 口径，不读 AX、不比 bounds）
//   - 兄弟序：同应用同标题按归一化「先 y 后 x」排序取序号（复用 Core/ConservativeMatch 同一规则，
//     与 verify 存活侧口径一致）

/// 快照几何覆盖（延迟几何待补写窗的目标；归一比例坐标，与快照同口径）
public struct WindowGeometryOverride: Equatable, Sendable {
    public let displayUUID: String
    public let x: Double, y: Double, w: Double, h: Double

    public init(displayUUID: String, x: Double, y: Double, w: Double, h: Double) {
        self.displayUUID = displayUUID
        self.x = x; self.y = y; self.w = w; self.h = h
    }
}

/// 延迟几何端口（生产实现 = RestoreEngine.DeferredGeometry；SnapshotEngine 不依赖 RestoreEngine）
public protocol DeferredGeometryPort: AnyObject, Sendable {
    /// 待补写窗的快照几何覆盖（windowID → 目标几何）
    func geometryOverrides() -> [UInt32: WindowGeometryOverride]
}

public struct SnapshotComposer: Sendable {
    private let spaces: SpaceProviding?
    private let ax: WindowAXProbing

    public init(spaces: SpaceProviding?, ax: WindowAXProbing) {
        self.spaces = spaces
        self.ax = ax
    }

    /// 组装 schema v1 快照（纯映射；存储由调用方负责）。
    /// geometryOverrides：待补写延迟几何的窗（windowID → 目标几何），同屏时按目标记录——
    /// 实况是 macOS 中间态（如躲 Dock 缩高），照实写会把它固化成下次恢复的目标（11-03 实测）
    public func compose(sample: [CGWindowSample], displays: [Displays.Info], capturedAt: Date,
                        geometryOverrides: [UInt32: WindowGeometryOverride] = [:]) -> Snapshot {
        let entries = loadSpaceEntries()
        let members = LiveWindowSet.collect(
            samples: sample.filter { !$0.bundleID.isEmpty }, displays: displays,
            spaceIDByWindow: loadSpaceIDsByWindow(), spaceEntries: entries,
            orderedOut: { ids in spaces?.orderedOutWindowIDs(among: ids) },
            minimized: { ax.minimizedWindowIDs($0) })

        var fullscreenBySpaceID: [Int64: String] = [:]
        struct Draft: SiblingSortable {
            let bundleID: String
            let title: String
            let displayUUID: String
            let spaceIndex: Int
            let x: Double, y: Double, w: Double, h: Double
            let minimized: Bool
        }
        var drafts: [Draft] = []

        for member in members {
            let lw = member.window
            let window = lw.sample, display = lw.display, entry = lw.space
            if let entry, entry.kind == SpaceKind.fullscreen {
                // 全屏应用：窗所在 Space kind == 全屏即是（SLS 口径，不依赖 bounds/AX；伴生工具条窗同理），
                // 改记到该 Space（spec §7.3），不进 windows；同 Space 多窗只记首个
                if fullscreenBySpaceID[entry.spaceID] == nil { fullscreenBySpaceID[entry.spaceID] = window.bundleID }
                continue
            }
            // 待补写窗：只在已就位目标屏时覆盖几何（屏归属仍按实况，未就位不伪造）
            let override = geometryOverrides[window.windowID].flatMap { $0.displayUUID == display.uuid ? $0 : nil }
            drafts.append(Draft(
                bundleID: window.bundleID,
                title: window.title ?? "",
                displayUUID: display.uuid ?? "",
                spaceIndex: entry?.index ?? 1,
                x: override.map { LiveWindowLocator.clampRatio($0.x) } ?? lw.x,
                y: override.map { LiveWindowLocator.clampRatio($0.y) } ?? lw.y,
                w: override.map { LiveWindowLocator.clampRatio($0.w) } ?? lw.w,
                h: override.map { LiveWindowLocator.clampRatio($0.h) } ?? lw.h,
                minimized: member.minimized))
        }

        // 兄弟序：与 ConservativeMatcher 存活侧同一排序规则（先 y 后 x，归一化坐标）
        var windows: [SnapshotWindow] = []
        var grouped: [String: [Draft]] = [:]
        for draft in drafts {
            grouped["\(draft.bundleID)\u{1}\(draft.title)", default: []].append(draft)
        }
        for (_, members) in grouped {
            for (rank, draft) in ConservativeMatcher.siblingOrder(members).enumerated() {
                windows.append(SnapshotWindow(
                    bundleID: draft.bundleID, title: draft.title, siblingIndex: rank,
                    displayUUID: draft.displayUUID, spaceIndex: draft.spaceIndex,
                    x: draft.x, y: draft.y, w: draft.w, h: draft.h, minimized: draft.minimized))
            }
        }
        windows.sort { ($0.bundleID, $0.title, $0.siblingIndex) < ($1.bundleID, $1.title, $1.siblingIndex) }

        var snapshotSpaces = entries.map { entry -> SnapshotSpace in
            let isFullscreen = entry.kind == SpaceKind.fullscreen
            return SnapshotSpace(
                displayUUID: entry.displayUUID, index: entry.index,
                kind: isFullscreen ? .fullscreen : .user,
                fullscreenAppBundleID: isFullscreen ? fullscreenBySpaceID[entry.spaceID] : nil)
        }
        snapshotSpaces.sort { ($0.displayUUID, $0.index) < ($1.displayUUID, $1.index) }

        return Snapshot(capturedAt: capturedAt,
                        topology: topologyEntries(displays),
                        spaces: snapshotSpaces,
                        windows: windows)
    }

    // MARK: 内部

    /// Space 数据不可用 → 降级为空（spaces=[]、spaceIndex=1，几何层照常）
    private func loadSpaceEntries() -> [SpaceEntry] {
        guard let spaces else { return [] }
        do { return try spaces.managedSpaces() }
        catch { return [] }
    }

    /// nil = Space 数据不可用（LiveWindowSet 据此不按归属排除）
    private func loadSpaceIDsByWindow() -> [UInt32: Int64]? {
        guard let spaces else { return nil }
        return try? spaces.spaceIDsByWindowID()
    }

    /// 拓扑条目：稳定 UUID + 整块 CGDisplayBounds + 捕获旋转角（spec §7.2/§7.3）。
    /// localizedName 与拓扑展示同源（Displays.localizedName：NSScreen.localizedName 优先）。
    private func topologyEntries(_ displays: [Displays.Info]) -> [TopologyDisplay] {
        displays.map { info in
            TopologyDisplay(
                uuid: info.uuid ?? "",
                localizedName: Displays.localizedName(for: info.id),
                frame: SnapshotDisplayFrame(x: Double(info.bounds.origin.x), y: Double(info.bounds.origin.y),
                                            w: Double(info.bounds.width), h: Double(info.bounds.height)),
                orientation: Displays.rotation(for: info.id))
        }
    }
}
