import Core
import CoreGraphics
import Foundation
import SnapshotEngine
import SpaceAdapter

// RestoreEngine.swift — 恢复引擎核心（票 14 L1+L2；票 15 L3 全屏最后 + L4 最小化恢复，spec §6.4/§6.5/§6.7/§6.8/§7.1/§7.4）。
// 一次性恢复（spec §6.3）：单轮写完即停，无重试循环；逐窗口逐层结构化日志（spec §10.4）+ 结束计数。
// 管线（§6.8 顺序铁律）：保守匹配 → 回滚快照（动手前）→ 逐窗口桥接 Space 移动（L2，屏+Space 一步到位）
//   → AX 几何摆位（L1，比例坐标 × 所属屏 CGDisplayBounds，旋转变化按轴向互换 best-effort）
//   → 全屏最后（L3：目标屏就位 → AXFullScreen=true → 等动画 §10.3）→ 最小化窗口恢复（L4，§6.5）。
// 全屏应用不进 windows 条目（schema §7.3），由快照 fullscreen Space 携带 bundleID 表示；全屏窗几何不触碰。
// 降级阶梯（§6.1）：L3/L4 各自经 SpaceLayer 探针逐层判定，某层不可用只降该层，其余照常。
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
    /// 处理条目级：无任何动作失败（常规窗 + 全屏 Space + 最小化窗；降级跳过不计失败，spec §6.1 逐层降级）
    public let okCount: Int
    /// 处理条目级：未匹配（含未运行）/ 目标屏缺失 / 降级层跳过（L3/L4 失效原地不动，spec §6.1/§6.5）
    public let skipCount: Int
    /// 处理条目级：任一动作 fail（桥接 no-op、AX 写失败等）
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
    /// L3 全屏写（AXFullScreen；票 15）
    private let fullscreen: WindowFullScreenWriting
    /// L4 最小化写（AXMinimized；票 15）
    private let minimize: WindowMinimizeWriting
    /// 全屏动画等待（§10.3 全屏动画等待 0.5–1s，取上限；测试注入 0 跳过）
    private let fullscreenSettleSeconds: TimeInterval
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
                fullscreen: WindowFullScreenWriting = AXFullScreenWriter(),
                minimize: WindowMinimizeWriting = AXMinimizeWriter(),
                fullscreenSettleSeconds: TimeInterval = 1.0,
                displaysProvider: @escaping () -> [Displays.Info] = Displays.active,
                rotationProvider: @escaping (CGDirectDisplayID) -> Int = Displays.rotation,
                log: LogWriting? = nil) {
        self.store = store
        self.spaces = spaces
        self.enumerator = enumerator
        self.ax = ax
        self.geometry = geometry
        self.fullscreen = fullscreen
        self.minimize = minimize
        self.fullscreenSettleSeconds = fullscreenSettleSeconds
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
        // → Pass L3（全屏最后）→ Pass L4（最小化恢复）—— §6.8 顺序铁律
        let bridgeOK = spaces.isBridgeAvailable() && !entries.isEmpty
        let actItems = plan.filter(\.canAct)
        var failed = Set<Int>()
        for item in actItems {
            bridgeMove(item, bridgeOK: bridgeOK, failed: &failed)
        }
        for item in actItems {
            place(item, failed: &failed)
        }

        // Pass L3（票 15）：快照 fullscreen Space（kind=fullscreen 携带 bundleID，不进 windows，§7.3）
        var ok3 = 0, skip3 = 0, fail3 = 0
        restoreFullscreenSpaces(snapshot: snapshot, live: live, entries: entries, displays: displays,
                                layerOK: spaces.isLayerAvailable(.fullscreen), bridgeOK: bridgeOK,
                                ok: &ok3, skipped: &skip3, failed: &fail3)

        // Pass L4（票 15，§6.8 顺序铁律最后一环）：最小化窗口送回快照 Space 并保持最小化
        let l4Items = plan.filter(\.isMinimizedRestore)
        let minimizedLayerOK = spaces.isLayerAvailable(.minimized)
        var ok4 = 0, skip4 = 0, fail4 = 0
        for item in l4Items {
            restoreMinimizedWindow(item, layerOK: minimizedLayerOK,
                                   ok: &ok4, skipped: &skip4, failed: &fail4)
        }

        let skipped = plan.count - actItems.count - l4Items.count
        let report = RestoreReport(
            okCount: actItems.count - failed.count + ok3 + ok4,
            skipCount: skipped + skip3 + skip4,
            failCount: failed.count + fail3 + fail4,
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
            /// 配对但不动（reason = target-display-absent）
            case skip(reason: String)
            /// 执行 L2+L1。targetSpace = nil 表示目标屏在拓扑内但无既有 Space 可落（仅降 L2，L1 照常）
            case act(live: LiveRestoreWindow, targetSpace: SpaceEntry?, mergedFrom: Int?,
                     targetDisplay: Displays.Info, capturedOrientation: Int)
            /// L4 最小化恢复（票 15，spec §6.5）：送回快照 Space 并保持最小化，几何不触碰
            case restoreMinimized(live: LiveRestoreWindow, targetSpace: SpaceEntry?, mergedFrom: Int?)
        }
        let snapshotIndex: Int
        let snapshotWindow: SnapshotWindow
        let action: Action

        var canAct: Bool {
            if case .act = action { return true }
            return false
        }

        var isMinimizedRestore: Bool {
            if case .restoreMinimized = action { return true }
            return false
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
            if lw.minimized {
                // L4（票 15，spec §6.5）：实况最小化 → 送回快照 Space 并保持最小化，几何不触碰。
                // 快照 minimized 但实况已展开 → 走常规恢复（终态是否最小化尊重实况，不强行重新最小化）
                let resolved = Self.resolveTargetSpace(
                    displayUUID: snap.displayUUID, snapshotIndex: snap.spaceIndex, entries: entries)
                plan.append(PlanItem(snapshotIndex: s, snapshotWindow: snap, action: .restoreMinimized(
                    live: lw, targetSpace: resolved?.entry, mergedFrom: resolved?.mergedFrom)))
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
            logSpaceMerge(wid: wid, app: snap.bundleID, display: snap.displayUUID,
                          from: from, to: targetSpace.index)
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

    // MARK: - Pass L3：全屏最后（票 15，spec §6.8 后半 + §5.1 指定屏全屏 + §5.2 进入后台可完成）

    /// 快照 fullscreen Space 逐条恢复：找该应用实况窗 → 目标屏就位（桥接预移位）→ AXFullScreen=true → 等动画。
    /// 全屏 Space(type=4) 由 AXFullScreen 在目标屏后台新建（验收 A17）；进入后台即可完成，不要求该 Space 可见
    /// （§5.2/§8.6：程序化不可达的「后台退出全屏」只咬撤销，票 16 两段式）。
    private func restoreFullscreenSpaces(snapshot: Snapshot, live: [LiveRestoreWindow],
                                         entries: [SpaceEntry], displays: [Displays.Info],
                                         layerOK: Bool, bridgeOK: Bool,
                                         ok: inout Int, skipped: inout Int, failed: inout Int) {
        var consumed = Set<UInt32>()  // 同应用多个全屏 Space 时，一个实况窗只消费一次
        for space in snapshot.spaces where space.kind == .fullscreen {
            let target = "\(space.displayUUID)/\(space.index)"
            guard let appID = space.fullscreenAppBundleID, !appID.isEmpty else {
                log?.write("[restore] skip app=- reason=fullscreen-app-missing detail=space=\(target)")
                skipped += 1
                continue
            }
            guard displays.contains(where: { $0.uuid == space.displayUUID }) else {
                log?.write("[restore] skip app=\(appID) reason=target-display-absent detail=fullscreen-space=\(target)")
                skipped += 1
                continue
            }
            guard layerOK else {
                // L3 降级（探针失败 / FORCE_DEGRADED=fullscreen）：全屏应用不动，其余层照常（§6.1）
                log?.write("[restore] skip app=\(appID) reason=fullscreen-layer-unavailable detail=space=\(target)")
                skipped += 1
                continue
            }
            guard let lw = live.first(where: { $0.bundleID == appID && !consumed.contains($0.cgWindowID) }) else {
                // 应用已退出不启动（spec §6.4a）
                log?.write("[restore] skip app=\(appID) reason=app-not-running detail=fullscreen-space=\(target)")
                skipped += 1
                continue
            }
            consumed.insert(lw.cgWindowID)
            let wid = lw.cgWindowID
            var before = "fullscreen=false disp=\(lw.displayUUID) space=\(lw.spaceID)"

            // 目标屏就位（05 #4：窗口先到目标屏；已在目标屏则免桥接）。预移位落点取目标屏既有 Space 之一即可
            if lw.displayUUID != space.displayUUID {
                guard fullscreenPreMove(wid: wid, appID: appID, displayUUID: space.displayUUID,
                                        target: target, before: &before, entries: entries, bridgeOK: bridgeOK,
                                        skipped: &skipped, failed: &failed) else { continue }
            }

            do {
                try fullscreen.setFullScreen(windowID: wid, true)
                if fullscreenSettleSeconds > 0 { Thread.sleep(forTimeInterval: fullscreenSettleSeconds) }
                log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.fullscreen, wid: wid, app: appID,
                    action: .fullscreen, target: target, before: before, after: "fullscreen=true", result: .ok))
                ok += 1
            } catch {
                failed += 1
                log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.fullscreen, wid: wid, app: appID,
                    action: .fullscreen, target: target, before: before, after: "-", result: .fail))
                logDetail(wid: wid, app: appID, action: .fullscreen, error: error)
            }
        }
    }

    /// L3 目标屏桥接预移位；返回 false = 该条目已处理完（skip/fail 已记）
    private func fullscreenPreMove(wid: UInt32, appID: String, displayUUID: String, target: String,
                                   before: inout String, entries: [SpaceEntry], bridgeOK: Bool,
                                   skipped: inout Int, failed: inout Int) -> Bool {
        guard bridgeOK,
              let landing = entries.filter({ $0.displayUUID == displayUUID })
                  .min(by: { $0.index < $1.index }) else {
            // 桥接不可用/目标屏无既有 Space：无法就位（§6.1 L3 失效表现 = 不动；L2 已另有降级日志）
            log?.write("[restore] skip wid=\(wid) app=\(appID) reason=fullscreen-premove-unavailable detail=space=\(target)")
            skipped += 1
            return false
        }
        do {
            let moved = try spaces.moveWindowsToSpace(windowIDs: [wid], spaceID: landing.spaceID)
            guard moved else {
                // no-op：桥接失效特征（适配器已记 [degrade]）→ 本窗无法就位，计失败
                log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.fullscreen, wid: wid, app: appID,
                    action: .fullscreen, target: target, before: before, after: "-", result: .fail))
                failed += 1
                return false
            }
            before += " prespace=\(landing.index)"
            return true
        } catch {
            // 桥接层失效连坐（探针未过 / FORCE_DEGRADED）：该全屏窗跳过，不判本窗失败（§6.1 只降不可用层）
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.fullscreen, wid: wid, app: appID,
                action: .fullscreen, target: target, before: before, after: "-", result: .skip))
            skipped += 1
            return false
        }
    }

    // MARK: - Pass L4：最小化窗口恢复（票 15，spec §6.5）

    /// 实况最小化窗口：取消最小化（实测自动落回原 Space，05 #5）→ 按需桥接移至快照 Space → 重新最小化。
    /// 先试最小化状态直接桥接（实测可行则省去首尾，语义不变）；失败不做运行时 no-op 标记，回退路径仍可用。
    /// L4 不可用（探针 / FORCE_DEGRADED=minimized）时原地保持最小化不动，不报失败（skip，§6.1/§6.5）。
    private func restoreMinimizedWindow(_ item: PlanItem, layerOK: Bool,
                                        ok: inout Int, skipped: inout Int, failed: inout Int) {
        guard case .restoreMinimized(let lw, let targetSpace, let mergedFrom) = item.action else { return }
        let snap = item.snapshotWindow
        let wid = lw.cgWindowID
        let target = "\(snap.displayUUID)/\(targetSpace?.index ?? snap.spaceIndex)"
        let before = "minimized=true space=\(lw.spaceID)"

        guard layerOK else {
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.minimized, wid: wid, app: snap.bundleID,
                action: .minimize, target: target, before: before, after: "-", result: .skip))
            skipped += 1
            return
        }
        guard let targetSpace else {
            log?.write("[restore] skip wid=\(wid) app=\(snap.bundleID) title=\(snap.title) reason=target-display-absent")
            skipped += 1
            return
        }
        if let from = mergedFrom {
            logSpaceMerge(wid: wid, app: snap.bundleID, display: snap.displayUUID,
                          from: from, to: targetSpace.index)
        }

        // §6.5：先试最小化状态下直接桥接（实现期可简化，语义不变）
        let direct: Bool?
        do { direct = try spaces.tryMoveMinimized(windowID: wid, spaceID: targetSpace.spaceID) }
        catch { direct = nil }
        if direct == true {
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.minimized, wid: wid, app: snap.bundleID,
                action: .minimize, target: target, before: before,
                after: "minimized=true space=\(targetSpace.spaceID)", result: .ok))
            ok += 1
            return
        }

        // 回退路径：取消最小化 → 桥接移至快照 Space → 重新最小化（终态 = 原地保持最小化，无论移窗成败）
        do {
            try minimize.setMinimized(windowID: wid, false)
            var moved: Bool?
            var bridgeError: Error?
            do { moved = try spaces.moveWindowsToSpace(windowIDs: [wid], spaceID: targetSpace.spaceID) }
            catch { bridgeError = error }
            var reMinimized = true
            do { try minimize.setMinimized(windowID: wid, true) } catch { reMinimized = false }

            if let moved {
                if moved && reMinimized {
                    log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.minimized, wid: wid,
                        app: snap.bundleID, action: .minimize, target: target, before: before,
                        after: "minimized=true space=\(targetSpace.spaceID)", result: .ok))
                    ok += 1
                } else {
                    // no-op（同 L2 口径计失败）或重最小化写失败（终态偏差）
                    failed += 1
                    log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.minimized, wid: wid,
                        app: snap.bundleID, action: .minimize, target: target, before: before,
                        after: "-", result: .fail))
                }
            } else {
                // 桥接层失效连坐（探针未过 / 运行时 no-op 已标死）：窗口已重最小化原地保持，不判本窗失败
                skipped += 1
                log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.minimized, wid: wid,
                    app: snap.bundleID, action: .minimize, target: target, before: before,
                    after: "minimized=true space=\(lw.spaceID)", result: .skip))
                if let bridgeError {
                    logDetail(wid: wid, app: snap.bundleID, action: .minimize, error: bridgeError)
                }
            }
        } catch {
            // 取消最小化写失败：窗口保持最小化原地，计失败
            failed += 1
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.minimized, wid: wid, app: snap.bundleID,
                action: .minimize, target: target, before: before, after: "-", result: .fail))
            logDetail(wid: wid, app: snap.bundleID, action: .minimize, error: error)
        }
    }

    /// A12：快照 Space 多出 → 按 index 就近并入既有 Space（spec §6.7 不补建；L2/L4 共用）
    private func logSpaceMerge(wid: UInt32, app: String, display: String, from snapshotIndex: Int, to index: Int) {
        log?.write("[restore] space-merge wid=\(wid) app=\(app) display=\(display) "
            + "snapshotIndex=\(snapshotIndex) mergedTo=\(index)")
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

/// 恢复降级阶梯层号（L1 几何 / L2 桥接 / L3 全屏 / L4 最小化，spec §6.1）
enum SpaceLayerNumber {
    static let geometry = 1
    static let bridge = 2
    static let fullscreen = 3
    static let minimized = 4
}
