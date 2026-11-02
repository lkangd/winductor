import Core
import CoreGraphics
import Darwin
import Foundation

// SnapshotComposer.swift — 快照内容映射（spec §7.3/§7.5）。仅在写盘路径执行。
// 口径：
//   - 窗口→displayUUID：Displays.active() 顺序上取 bounds 交集最大者；无交集回退 Space 归属屏
//   - 窗口→spaceIndex：Core/Seams 的 SpaceProviding 接缝（spaceIDsByWindowID → SpaceEntry.index）；
//     Space 数据不可用时降级：spaces=[]、spaceIndex=1（几何层仍可恢复，spec §8.5 降级阶梯）
//   - minimized：仅对离屏候选读 AXMinimized；在屏窗口恒 false
//   - AXFullScreen==true 的整屏窗口不进 windows，改记到所属全屏 Space 的 fullscreenAppBundleID
//     （spec §7.3：全屏应用由 Space 携带，不进 windows）
//   - 兄弟序：同应用同标题按归一化「先 y 后 x」排序取序号（复用 Core/ConservativeMatch 同一规则，
//     与 verify 存活侧口径一致）

public struct SnapshotComposer: Sendable {
    private let spaces: SpaceProviding?
    private let ax: WindowAXProbing

    public init(spaces: SpaceProviding?, ax: WindowAXProbing) {
        self.spaces = spaces
        self.ax = ax
    }

    /// 组装 schema v1 快照（纯映射；IO 由调用方经 SnapshotStore 落盘）
    public func compose(sample: [CGWindowSample], displays: [Displays.Info], capturedAt: Date) -> Snapshot {
        let entries = loadSpaceEntries()
        let widToSpaceID = loadSpaceIDsByWindow()
        let spaceByID = Dictionary(entries.map { ($0.spaceID, $0) }, uniquingKeysWith: { a, _ in a })

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

        for window in sample {
            guard !window.bundleID.isEmpty else { continue }
            let entry = widToSpaceID[window.windowID].flatMap { spaceByID[$0] }
            // 归属以 Space 所有权为权威（SLS），frame 相交仅兜底：非可见 Space 后台窗的
            // AX frame 是过期值，相交会归错屏（实测：内置屏后台窗被记到中屏，restore 据此移错），
            // 故先查 window 所在 Space 的所属屏，无 Space 归属才按 frame 定屏。
            guard let display = displays.first(where: { $0.uuid == entry?.displayUUID })
                ?? pickDisplay(window.bounds, in: displays) else {
                continue  // 无 Space 归属且落不到任何屏：无从记录，跳过
            }
            var minimized = false
            var axFullScreen = false
            if !window.isOnscreen || window.bounds == display.bounds {
                // AX 仅写盘路径、按候选个位数次（离屏读 minimized；整屏候选读 fullscreen）
                let state = ax.probe(pid: window.pid, windowID: window.windowID)
                minimized = window.isOnscreen ? false : state.minimized
                axFullScreen = state.fullScreen
            }
            if axFullScreen {
                // 全屏应用：改记到所属全屏 Space（spec §7.3），不进 windows
                if let entry {
                    fullscreenBySpaceID[entry.spaceID] = window.bundleID
                }
                continue
            }
            let w = display.bounds.width, h = display.bounds.height
            func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
            drafts.append(Draft(
                bundleID: window.bundleID,
                title: window.title ?? "",
                displayUUID: display.uuid ?? "",
                spaceIndex: entry?.index ?? 1,
                x: clamp01((window.bounds.minX - display.bounds.minX) / w),
                y: clamp01((window.bounds.minY - display.bounds.minY) / h),
                w: clamp01(window.bounds.width / w),
                h: clamp01(window.bounds.height / h),
                minimized: minimized))
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
            let isFullscreen = entry.kind == 4
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

    /// bounds 交集最大者（displays 已按左→右排序，同积取先者）
    private func pickDisplay(_ bounds: CGRect, in displays: [Displays.Info]) -> Displays.Info? {
        var best: (info: Displays.Info, area: Double)?
        for info in displays {
            let inter = info.bounds.intersection(bounds)
            guard !inter.isNull, inter.width > 0, inter.height > 0 else { continue }
            let area = Double(inter.width * inter.height)
            if best == nil || area > best!.area { best = (info, area) }
        }
        return best?.info
    }

    /// Space 数据不可用 → 降级为空（spaces=[]、spaceIndex=1，几何层照常）
    private func loadSpaceEntries() -> [SpaceEntry] {
        guard let spaces else { return [] }
        do { return try spaces.managedSpaces() }
        catch { return [] }
    }

    private func loadSpaceIDsByWindow() -> [UInt32: Int64] {
        guard let spaces else { return [:] }
        do { return try spaces.spaceIDsByWindowID() }
        catch { return [:] }
    }

    /// 拓扑条目：稳定 UUID + 整块 CGDisplayBounds + 捕获旋转角（spec §7.2/§7.3）。
    /// localizedName 经 dlsym 取 CGDisplayGetName（Swift 不直接导出），失败回退 "Display <id>"。
    private static let displayNameFn: @convention(c) (UInt32) -> CFString? = {
        for lib in ["/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", ""] {
            let h = lib.isEmpty ? dlopen(nil, RTLD_LAZY) : dlopen(lib, RTLD_LAZY)
            guard let hh = h, let p = dlsym(hh, "CGDisplayGetName") else { continue }
            return unsafeBitCast(p, to: (@convention(c) (UInt32) -> CFString?).self)
        }
        return { _ in nil }
    }()

    private func topologyEntries(_ displays: [Displays.Info]) -> [TopologyDisplay] {
        displays.map { info in
            TopologyDisplay(
                uuid: info.uuid ?? "",
                localizedName: Self.displayNameFn(info.id) as String? ?? "Display \(info.id)",
                frame: SnapshotDisplayFrame(x: Double(info.bounds.origin.x), y: Double(info.bounds.origin.y),
                                            w: Double(info.bounds.width), h: Double(info.bounds.height)),
                orientation: Displays.rotation(for: info.id))
        }
    }
}
