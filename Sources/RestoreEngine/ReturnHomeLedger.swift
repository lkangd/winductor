import Core
import Foundation

// ReturnHomeLedger.swift — 冻结点账本（TriggerChain 的拔屏/插回恢复源判定）。
// 拔屏时冻结拔屏前拓扑的快照内容；回到该拓扑才自动恢复，且恢复源用冻结内容。
// 背景（实测缺陷 11-03）：插回后 poller 会把 macOS 中间态重排写进 live 快照，触发时现读即垃圾基线；
// 中间态拓扑也可能精确命中过期快照触发全量垃圾恢复（如 2 屏键）。
// 按拓扑分键：多段拔屏 3→2→1 每段各冻结一份，后段不覆盖外层（11-03 03:54 单槽被第二段降级为 2 屏）。
// 调用方持锁（TriggerChain.stateLock）；日志由调用方按返回值落 [trigger] 行。

/// 插回（集合变大）时的冻结点判定
enum ReturnDecision: Equatable {
    /// 无冻结点：按现存拓扑精确匹配
    case unguarded
    /// 回到某段拔屏前拓扑：恢复源 = 冻结内容（nil = 冻结时就没有快照，回退现存匹配）
    case home(Snapshot?)
    /// 插回冻结点的超集：放行，回退现存匹配
    case supersetOfHome(homeDisplays: Int)
    /// 中间拓扑（既非冻结点也非其超集）：不自动恢复，等回到冻结拓扑
    case intermediate(homeDisplays: Int)
}

struct ReturnHomeLedger {
    private let store: SnapshotStore
    /// 拓扑集合 → 冻结的拔屏前快照
    private var homes: [Set<String>: Snapshot?] = [:]
    /// 事件串首个事件到达时的基线 live 快照。冻结取它而非 settle 时现读：
    /// 实测 11-03 09:08 拔屏开始后在途写盘把中途态落进 live-<拔屏前拓扑>，settle 现读冻结了垃圾
    private var burst: (uuids: Set<String>, snapshot: Snapshot?)?
    /// 本次 settle 取走的事件串起点基线（仅当集合仍是 settle 基线；nil = 无，需现读）
    private var settledHeld: Snapshot??

    init(store: SnapshotStore) {
        self.store = store
    }

    /// 少屏状态下启动（拔屏开会时 app 重启 / 登录启动）：内存冻结点为空，插回时中间拓扑会精确命中
    /// 陈旧快照被当正常拓扑恢复（实测事故 11-03 07:39）。按磁盘上「当前集合的极大超集拓扑」重建冻结点：
    /// 当前缺屏 ⇒ 这些拓扑自拔屏后不可能被 poller 写过 = 拔屏前内容。非极大超集（如 3 屏的 2 屏子集）
    /// 不冻结 = 视为中间拓扑。返回重建的冻结点（日志用）。
    mutating func seedAtLaunch(current: Set<String>) -> [(uuids: Set<String>, held: Snapshot?)] {
        guard !current.isEmpty else { return [] }
        let supersets = liveTopologies().filter { current.isSubset(of: $0) && $0.count > current.count }
        let maximal = supersets.filter { candidate in
            !supersets.contains { candidate.isSubset(of: $0) && $0.count > candidate.count }
        }
        return maximal.map { uuids in
            let held = loadLive(uuids)
            homes[uuids] = .some(held)
            return (uuids, held)
        }
    }

    /// 快照目录里 live- 文件反拆出的拓扑集合
    private func liveTopologies() -> [Set<String>] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: store.directory,
                                                                         includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { file -> Set<String>? in
            let name = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "json", name.hasPrefix("live-"),
                  let uuids = SnapshotStore.displayUUIDs(inTopologyKey: String(name.dropFirst("live-".count))) else { return nil }
            return Set(uuids)
        }
    }

    /// 事件串开始（idle → debouncing）：记下此刻基线拓扑的 live 快照
    mutating func burstStarted(baseline: Set<String>) {
        burst = (baseline, loadLive(baseline))
    }

    /// 防抖结束（settle）时调用：取走事件串起点基线，供本次 settle 的冻结使用
    mutating func settle(baseline: Set<String>) {
        settledHeld = burst.flatMap { $0.uuids == baseline ? .some($0.snapshot) : nil }
        burst = nil
    }

    enum FreezeResult: Equatable {
        case frozen(Snapshot?)
        case alreadyHeld
    }

    /// 快速拔→插回（同处防抖静默期，settle 时已回到基线）：按「回到基线拓扑」处理；
    /// 该拓扑已有冻结点则保留更早的拔屏前内容，不现读覆盖
    mutating func fastReplugged(to baseline: Set<String>) -> FreezeResult {
        guard homes[baseline] == nil else { return .alreadyHeld }
        let held = heldBaseline(baseline)
        homes[baseline] = .some(held)
        return .frozen(held)
    }

    /// 拔出（集合变小）：冻结拔屏前基线（覆盖同拓扑旧冻结点）。返回冻结内容（日志 held/miss）
    @discardableResult
    mutating func unplugged(from baseline: Set<String>) -> Snapshot? {
        let held = heldBaseline(baseline)
        homes[baseline] = .some(held)
        return held
    }

    mutating func returnTo(_ current: Set<String>) -> ReturnDecision {
        guard !homes.isEmpty else { return .unguarded }
        let decision: ReturnDecision
        if let home = homes[current] {
            decision = .home(home)
        } else {
            let homeDisplays = homes.keys.map(\.count).max() ?? 0
            guard homes.keys.contains(where: { $0.isSubset(of: current) && current.count > $0.count }) else {
                return .intermediate(homeDisplays: homeDisplays)
            }
            decision = .supersetOfHome(homeDisplays: homeDisplays)
        }
        // ⊆ current 的冻结点已被本次回归取代（下次拔屏重新冻结）；⊋ current 的外层冻结点保留待回归
        homes = homes.filter { !$0.key.isSubset(of: current) }
        return decision
    }

    private func heldBaseline(_ baseline: Set<String>) -> Snapshot? {
        if let settledHeld { return settledHeld }
        return loadLive(baseline)
    }

    private func loadLive(_ uuids: Set<String>) -> Snapshot? {
        store.loadLive(topologyKey: SnapshotStore.topologyKey(forDisplayUUIDs: uuids.sorted()))
    }
}
