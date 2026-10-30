import Core
import CoreGraphics
import Foundation
import SnapshotEngine

// RestoreEngine.swift — 恢复引擎核心（票 14，spec §6.4/§6.7/§6.8/§7.1/§7.4）。
// 一次性恢复（spec §6.3）：单轮写完即停，无重试循环；逐窗口逐层结构化日志（spec §10.4）+ 结束计数。
// 管线（§6.8 前半）：保守匹配 → 回滚快照（动手前）→ 逐窗口桥接 Space 移动（L2，屏+Space 一步到位）
//   → AX 几何摆位（L1，比例坐标 × 所属屏 CGDisplayBounds，旋转变化按轴向互换 best-effort）。
// L3 全屏 / L4 最小化本票不碰（票 15）：快照 minimized 条目与实况最小化窗口一律 skip。
// 保守匹配（spec §6.4）：Core.ConservativeMatcher（verify 共用同一份，08 #1）；
//   未运行应用不启动、快照外窗口/应用不动、粘性窗与无归属辅助窗不入恢复集合（spec §5.3）。

/// 引擎无法启动的错误（逐窗口问题不 throw，走 best-effort 日志 + 计数，spec §6.3）
public enum RestoreEngineError: Error, Equatable, Sendable {
    case noActiveDisplay
    /// 回滚快照写失败：无撤销保险不动手，整个恢复中止（spec §7.4「恢复中途崩溃撤销必须在」）
    case undoSnapshotWriteFailed(String)
}

/// 一次性恢复的结果（spec §6.3：结束产出成功/跳过/失败计数；票 15/16 增量扩展）
public struct RestoreReport: Equatable, Sendable {
    /// 快照条目级：无任何动作失败（L2 降级跳过不计失败，spec §6.1 逐层降级）
    public let okCount: Int
    /// 快照条目级：未匹配（含未运行）/ 最小化（L4 票 15）/ 目标屏缺失
    public let skipCount: Int
    /// 快照条目级：任一动作 fail（桥接 no-op、AX 写失败等）
    public let failCount: Int
    /// 配对条目数（一级 + 二级几何兜底）
    public let matchedCount: Int
    /// 快照外不动窗口数（spec §6.4b）
    public let untouchedLiveCount: Int
    /// 回滚快照落点
    public let undoSnapshotURL: URL?
}

/// 恢复视角的实况窗口（单 Space 归属；粘性窗/无归属辅助窗不入列 = 保守「不动」，spec §5.3）
public struct LiveRestoreWindow: Equatable, Sendable {
    public let cgWindowID: UInt32
    public let bundleID: String
    public let title: String
    /// 当前所属屏稳定 UUID（中心点归属，与 VerifyCLI 同口径）
    public let displayUUID: String
    /// 当前 Space id64（SLSCopySpacesForWindows 单归属）
    public let spaceID: Int64
    /// 所属屏归一比例坐标（spec §7.2）
    public let x: Double, y: Double, w: Double, h: Double
    public let minimized: Bool
}

public final class RestoreEngine: @unchecked Sendable {
    private let store: SnapshotStore
    private let spaces: SpaceBridge
    private let enumerator: WindowEnumerating
    private let ax: WindowAXProbing
    private let geometry: WindowGeometryWriting
    private let displaysProvider: () -> [Displays.Info]
    private let rotationProvider: (CGDirectDisplayID) -> Int
    private let log: LogWriting?
    /// 回滚快照组装复用票 12 的 SnapshotComposer（同一 schema 口径，spec §7.3）
    private let composer: SnapshotComposer

    public init(store: SnapshotStore,
                spaces: SpaceBridge,
                enumerator: WindowEnumerating = CGWindowListEnumerator(),
                ax: WindowAXProbing = MinimalAXReader(),
                geometry: WindowGeometryWriting = AXGeometryWriter(),
                displaysProvider: @escaping () -> [Displays.Info] = Displays.active,
                rotationProvider: @escaping (CGDirectDisplayID) -> Int = Displays.rotation,
                log: LogWriting? = nil) {
        self.store = store
        self.spaces = spaces
        self.enumerator = enumerator
        self.ax = ax
        self.geometry = geometry
        self.displaysProvider = displaysProvider
        self.rotationProvider = rotationProvider
        self.log = log
        self.composer = SnapshotComposer(spaces: spaces, ax: ax)
    }

    /// 一次性恢复入口。抛错仅限「无法启动」（无显示器 / 回滚快照写失败）；
    /// 逐窗口问题一律记日志计数，不中断（spec §6.3 单轮 best-effort）。
    @discardableResult
    public func restore(snapshot: Snapshot) throws -> RestoreReport {
        let displays = displaysProvider()
        guard !displays.isEmpty else {
            log?.write("[restore] abort reason=no-active-display")
            throw RestoreEngineError.noActiveDisplay
        }
        let key = SnapshotStore.topologyKey(
            forDisplayUUIDs: displays.compactMap(\.uuid).filter { !$0.isEmpty })

        // §7.4：动手前先落回滚快照（当前实况按 schema 写 undo-<拓扑键>.json）；失败即中止
        let undoURL = store.undoURL(topologyKey: key)
        do {
            let undo = composer.compose(sample: enumerator.sample(), displays: displays, capturedAt: Date())
            try SnapshotStore.atomicWrite(try undo.encoded(), to: undoURL)
            log?.write("[snapshot] action=write path=\(undoURL.lastPathComponent) result=ok "
                + "detail=windows=\(undo.windows.count)")
        } catch {
            log?.write("[snapshot] action=write path=\(undoURL.lastPathComponent) result=fail detail=\(error)")
            throw RestoreEngineError.undoSnapshotWriteFailed(String(describing: error))
        }

        // 保守匹配（Core 共用代码，spec §7.1）+ 逐条目行动计划
        let live = collectLiveWindows(samples: enumerator.sample(), displays: displays)
        let outcome = ConservativeMatcher.match(
            snapshotWindows: snapshot.windows,
            liveWindows: live.map { LiveWindow(cgWindowID: $0.cgWindowID, bundleID: $0.bundleID,
                                               title: $0.title, x: $0.x, y: $0.y, w: $0.w, h: $0.h,
                                               minimized: $0.minimized) })
        let entries = (try? spaces.managedSpaces()) ?? []
        let plan = planEntries(snapshot: snapshot, live: live, outcome: outcome,
                               entries: entries, displays: displays)

        // Pass L2（§6.8 先桥接移窗：屏 + Space 一步到位）→ Pass L1（AX 几何摆位）
        let bridgeOK = spaces.isBridgeAvailable() && !entries.isEmpty
        var failed = Set<Int>()
        for item in plan where item.canAct {
            bridgeMove(item, bridgeOK: bridgeOK, failed: &failed)
        }
        for item in plan where item.canAct {
            place(item, failed: &failed)
        }

        let skipped = plan.filter { !$0.canAct }.count
        let report = RestoreReport(
            okCount: snapshot.windows.count - skipped - failed.count,
            skipCount: skipped,
            failCount: failed.count,
            matchedCount: outcome.matches.count,
            untouchedLiveCount: outcome.unmatchedLiveIndexes.count,
            undoSnapshotURL: undoURL)
        log?.write("[restore] done ok=\(report.okCount) skip=\(report.skipCount) fail=\(report.failCount) "
            + "matched=\(report.matchedCount) untouched=\(report.untouchedLiveCount)")
        return report
    }

    // MARK: - 行动计划（匹配结果 → 每条目动作/跳过判定；skip 行只记一次）

    struct PlanItem {
        enum Action {
            /// 未配对（reason = app-not-running | unmatched，spec §6.4a/c）
            case unmatched(reason: String)
            /// 配对但不动（reason = minimized-entry-L4 | live-minimized | target-display-absent）
            case skip(reason: String)
            /// 执行 L2+L1。targetSpace = nil 表示目标屏在拓扑内但无既有 Space 可落（仅降 L2，L1 照常）
            case act(live: LiveRestoreWindow, targetSpace: SpaceEntry?, mergedFrom: Int?,
                     targetDisplay: Displays.Info, capturedOrientation: Int)
        }
        let snapshotIndex: Int
        let snapshotWindow: SnapshotWindow
        let action: Action

        var canAct: Bool {
            switch action {
            case .act: return true
            case .unmatched, .skip: return false
            }
        }
    }

    private func planEntries(snapshot: Snapshot, live: [LiveRestoreWindow],
                             outcome: MatchOutcome, entries: [SpaceEntry],
                             displays: [Displays.Info]) -> [PlanItem] {
        let matchBySnapshot = Dictionary(uniqueKeysWithValues: outcome.matches.map { ($0.snapshotIndex, $0) })
        let liveBundleIDs = Set(live.map(\.bundleID))
        let capturedOrientation = Dictionary(uniqueKeysWithValues:
            snapshot.topology.map { ($0.uuid, $0.orientation) })
        var plan: [PlanItem] = []
        func skipItem(_ s: Int, _ snap: SnapshotWindow, _ reason: String, wid: UInt32?) -> PlanItem {
            log?.write("[restore] skip wid=\(wid.map(String.init) ?? "-") app=\(snap.bundleID) "
                + "title=\(snap.title) reason=\(reason)")
            return PlanItem(snapshotIndex: s, snapshotWindow: snap,
                            action: .skip(reason: reason))
        }
        for (s, snap) in snapshot.windows.enumerated() {
            guard let match = matchBySnapshot[s] else {
                // 未运行应用不启动 / 同应用配不上不猜（spec §6.4a/c）
                let reason = liveBundleIDs.contains(snap.bundleID) ? "unmatched" : "app-not-running"
                plan.append(skipItem(s, snap, reason, wid: nil))
                continue
            }
            let lw = live[match.liveIndex]
            if snap.minimized {
                plan.append(skipItem(s, snap, "minimized-entry-L4", wid: lw.cgWindowID))  // L4 票 15
                continue
            }
            if lw.minimized {
                plan.append(skipItem(s, snap, "live-minimized", wid: lw.cgWindowID))  // 保守不动，L4 归口票 15
                continue
            }
            guard let targetDisplay = displays.first(where: { $0.uuid == snap.displayUUID }) else {
                plan.append(skipItem(s, snap, "target-display-absent", wid: lw.cgWindowID))
                continue
            }
            let resolved = Self.resolveTargetSpace(
                displayUUID: snap.displayUUID, snapshotIndex: snap.spaceIndex, entries: entries)
            plan.append(PlanItem(snapshotIndex: s, snapshotWindow: snap, action: .act(
                live: lw, targetSpace: resolved?.entry, mergedFrom: resolved?.mergedFrom,
                targetDisplay: targetDisplay, capturedOrientation: capturedOrientation[snap.displayUUID] ?? 0)))
        }
        return plan
    }

    // MARK: - Pass L2：桥接 Space 移动（屏 + Space 一步到位，spec §6.8）

    private func bridgeMove(_ item: PlanItem, bridgeOK: Bool, failed: inout Set<Int>) {
        guard case .act(let lw, let targetSpace, let mergedFrom, _, _) = item.action else { return }
        let snap = item.snapshotWindow
        let wid = lw.cgWindowID
        let target = "\(snap.displayUUID)/\(targetSpace?.index ?? snap.spaceIndex)"

        guard bridgeOK, let targetSpace else {
            // L2 降级（探针失败 / 运行时 no-op / FORCE_DEGRADED / 无既有 Space 可落）：该层跳过，L1 照常（§6.1）
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.bridge, wid: wid, app: snap.bundleID,
                action: .moveToSpace, target: target, before: "space=\(lw.spaceID)", after: "-", result: .skip))
            return
        }
        if let from = mergedFrom {
            // A12：快照 Space 多出 → 按 index 就近并入既有 Space（spec §6.7 不补建）
            log?.write("[restore] space-merge wid=\(wid) app=\(snap.bundleID) display=\(snap.displayUUID) "
                + "snapshotIndex=\(from) mergedTo=\(targetSpace.index)")
        }
        do {
            let moved = try spaces.moveWindowsToSpace(windowIDs: [wid], spaceID: targetSpace.spaceID)
            // false = perform 后归属未变更（no-op，适配器已记 [degrade] 并标记该层失效）→ 计失败
            if !moved { failed.insert(item.snapshotIndex) }
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.bridge, wid: wid, app: snap.bundleID,
                action: .moveToSpace, target: target,
                before: "space=\(lw.spaceID)", after: "space=\(targetSpace.spaceID)",
                result: moved ? .ok : .fail))
        } catch {
            failed.insert(item.snapshotIndex)
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.bridge, wid: wid, app: snap.bundleID,
                action: .moveToSpace, target: target, before: "space=\(lw.spaceID)", after: "-", result: .fail))
            logDetail(wid: wid, app: snap.bundleID, action: .moveToSpace, error: error)
        }
    }

    // MARK: - Pass L1：AX 几何摆位（比例坐标 × 所属屏 CGDisplayBounds，spec §7.2）

    private func place(_ item: PlanItem, failed: inout Set<Int>) {
        guard case .act(let lw, _, _, let targetDisplay, let capturedOrientation) = item.action else { return }
        let snap = item.snapshotWindow
        let wid = lw.cgWindowID
        let bounds = targetDisplay.bounds

        // 旋转处理（spec §6.6/§7.2）：捕获角与当前角轴向一致直接比例恢复；
        // 跨竖横（90/270 对 0/180）按轴向互换 best-effort
        let current = rotationProvider(targetDisplay.id)
        let swap = (capturedOrientation % 180) != (current % 180)
        let rx = swap ? snap.y : snap.x
        let ry = swap ? snap.x : snap.y
        let rw = swap ? snap.h : snap.w
        let rh = swap ? snap.w : snap.h
        let position = CGPoint(x: bounds.minX + CGFloat(rx) * bounds.width,
                               y: bounds.minY + CGFloat(ry) * bounds.height)
        let size = CGSize(width: CGFloat(rw) * bounds.width, height: CGFloat(rh) * bounds.height)
        let before = Self.ratioString(x: lw.x, y: lw.y, w: lw.w, h: lw.h)
        let after = Self.ratioString(x: rx, y: ry, w: rw, h: rh)

        do {
            try geometry.apply(windowID: wid, position: position, size: size)
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.geometry, wid: wid, app: snap.bundleID,
                action: .position, target: "\(snap.displayUUID) rot=\(current)",
                before: before, after: after, result: .ok))
        } catch {
            // 「AX 权限不足」等写失败：单轮 best-effort，计 fail 不中断（本票验收行为之一）
            failed.insert(item.snapshotIndex)
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.geometry, wid: wid, app: snap.bundleID,
                action: .position, target: "\(snap.displayUUID) rot=\(current)",
                before: before, after: after, result: .fail))
            logDetail(wid: wid, app: snap.bundleID, action: .position, error: error)
        }
    }

    // MARK: - 实况收集

    /// CG 采样 → 恢复集合：单 Space 归属（粘性/辅助窗排除）、中心点归属屏、离屏候选读 AX minimized
    private func collectLiveWindows(samples: [CGWindowSample], displays: [Displays.Info]) -> [LiveRestoreWindow] {
        let spaceByWindow = (try? spaces.spaceIDsByWindowID()) ?? [:]
        var out: [LiveRestoreWindow] = []
        for sample in samples {
            guard let spaceID = spaceByWindow[sample.windowID] else { continue }
            guard let display = Self.display(for: sample.bounds, in: displays),
                  let uuid = display.uuid, !uuid.isEmpty else { continue }
            let bounds = display.bounds
            guard bounds.width > 0, bounds.height > 0 else { continue }
            var minimized = false
            if !sample.isOnscreen {
                minimized = ax.probe(pid: sample.pid, windowID: sample.windowID).minimized
            }
            func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
            out.append(LiveRestoreWindow(
                cgWindowID: sample.windowID, bundleID: sample.bundleID, title: sample.title ?? "",
                displayUUID: uuid, spaceID: spaceID,
                x: clamp01(Double(sample.bounds.minX - bounds.minX) / Double(bounds.width)),
                y: clamp01(Double(sample.bounds.minY - bounds.minY) / Double(bounds.height)),
                w: clamp01(Double(sample.bounds.width) / Double(bounds.width)),
                h: clamp01(Double(sample.bounds.height) / Double(bounds.height)),
                minimized: minimized))
        }
        return out
    }

    // MARK: - 辅助

    /// Space 数量不符双向处置（spec §6.7）：
    ///   快照 index 命中既有 Space → 原样落位；快照多出 → 按 index 就近并入（不补建）；
    ///   目标屏无任何 Space → nil。现状多出（A13）无需特判：快照 index 照常命中落位。
    static func resolveTargetSpace(displayUUID: String, snapshotIndex: Int,
                                   entries: [SpaceEntry]) -> (entry: SpaceEntry, mergedFrom: Int?)? {
        let onDisplay = entries.filter { $0.displayUUID == displayUUID }.sorted { $0.index < $1.index }
        if let exact = onDisplay.first(where: { $0.index == snapshotIndex }) {
            return (exact, nil)
        }
        guard let nearest = onDisplay.min(by: {
            abs($0.index - snapshotIndex) < abs($1.index - snapshotIndex)
        }) else { return nil }
        return (nearest, snapshotIndex)
    }

    /// 窗口归属屏：中心点包含则取之，否则取中心距离最近者（与 VerifyCLI 同口径）
    static func display(for bounds: CGRect, in displays: [Displays.Info]) -> Displays.Info? {
        guard !displays.isEmpty else { return nil }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if let hit = displays.first(where: { $0.bounds.contains(center) }) { return hit }
        return displays.min {
            hypot($0.bounds.midX - center.x, $0.bounds.midY - center.y)
                < hypot($1.bounds.midX - center.x, $1.bounds.midY - center.y)
        }
    }

    static func ratioString(x: Double, y: Double, w: Double, h: Double) -> String {
        "(\(String(format: "%.4f", x)),\(String(format: "%.4f", y)),\(String(format: "%.4f", w)),\(String(format: "%.4f", h)))"
    }

    /// 失败详情行（spec §6.3「失败详情进日志」；§10.4 主行格式保持原样，详情独立成行）
    private func logDetail(wid: UInt32, app: String, action: RestoreAction, error: Error) {
        log?.write("[restore] detail wid=\(wid) app=\(app) action=\(action.rawValue) error=\(error)")
    }
}

/// 恢复降级阶梯层号（L1 几何 / L2 桥接；L3/L4 票 15 增量）
enum SpaceLayerNumber {
    static let geometry = 1
    static let bridge = 2
}
