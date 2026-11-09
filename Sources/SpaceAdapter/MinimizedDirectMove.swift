import Core
import Foundation

// MinimizedDirectMove.swift — SpaceAdapter 小增量（票 15，新增文件理由见票 15 报告）：
// 最小化窗口的「直接桥接」尝试（spec §6.5：实测最小化状态可直接桥接则省去取消/重最小化首尾）。
// 与 moveWindowsToSpace 的关键差别：失败不做运行时 no-op 标记（不写 runtimeNoOpLayers）——
// 最小化窗直移失败只说明「该窗不能直移」，不应毒化 L2 桥接层（标记持续到本轮结束），
// 否则 §6.5 回退路径（取消最小化 → 桥接 → 重最小化）会被 layerUnavailable 卡死。
// 票 16：同目标 Space 一批窗一次 perform + 一次轮询结算（原逐窗固定 1.2s 等待，实测 12 窗 ≈ 13s 纯等待）。
extension SpaceAdapter {
    /// 最小化窗口批量直接桥接尝试（同一目标 Space）。
    /// - Returns: 归属实际变更（或已在目标 Space）的窗；不在其中的窗 = 未迁移（不标记层失效，调用方逐窗走回退路径）
    /// - Throws: `SpaceAdapterError.layerUnavailable(.bridge)`（探针未过 / 已失效 / FORCE_DEGRADED）；
    ///   `bridgedOpFailed`（perform 报错 / 超时，整组走回退）
    @discardableResult
    public func tryMoveMinimized(windowIDs wids: [UInt32], spaceID: Int64) throws -> Set<UInt32> {
        guard isLayerAvailable(.bridge) else { throw SpaceAdapterError.layerUnavailable(.bridge) }
        return try Self.directMoveMinimized(
            wids, spaceID: spaceID, settle: settleSeconds, poll: Self.settlePollSeconds,
            readTimeout: Self.bridgeReadTimeoutSeconds,
            reader: spaceReader ?? { [weak self] in try self!.spaceIDs(windowID: $0) },
            log: log)
    }

    /// 批量直移本体（reader / runner 注入便于单测）：
    /// 读移前归属 → 已在目标的窗直接计入 → 其余一次 perform → 逐窗轮询结算（全部变更即返回，未变更等满 settle）
    static func directMoveMinimized(
        _ wids: [UInt32], spaceID: Int64, settle: TimeInterval, poll: TimeInterval,
        readTimeout: TimeInterval, reader: @escaping (UInt32) throws -> [Int64],
        runner: @escaping ([UInt32], UInt64) -> String? = { SpaceAdapter.performBridgedMove($0, spaceID: $1) },
        log: LogWriting? = nil
    ) throws -> Set<UInt32> {
        var done = Set<UInt32>()
        var toMove: [UInt32] = []
        var before: [[Int64]] = []
        for wid in wids {
            // 移前归属读取超时：该窗不进 perform（归属未知无从校验），按未迁移交调用方回退
            guard let ids = spaceIDsBounded(wid, timeout: readTimeout, reader: reader) else { continue }
            if ids == [spaceID] { done.insert(wid); continue }
            toMove.append(wid)
            before.append(ids)
        }
        if toMove.isEmpty { return done }

        // 限时执行（同 moveWindowsToSpace；超时按整组未迁移处理，调用方走 §6.5 回退保持最小化）
        switch performBridgedMoveBounded(toMove, spaceID: UInt64(spaceID), timeout: bridgeOpTimeoutSeconds,
                                         runner: runner) {
        case .completed(let issue):
            if let issue { throw SpaceAdapterError.bridgedOpFailed(issue) }
        case .timedOut:
            throw SpaceAdapterError.bridgedOpFailed("bridge-timeout")
        }
        let settled = awaitAttributionChanges(toMove, before: before, settle: settle, poll: poll,
                                              readTimeout: readTimeout, reader: reader)
        // 校验读取超时：归属未知 → 按已迁移处理（同 moveWindowsToSpace 口径：op 未报错即大概率成功），落观测日志
        for wid in settled.unknown {
            log?.write(StructuredLog.degradeLine(layer: SpaceLayer.bridge.layerNumber, reason: "verify-timeout",
                      detail: "minimized wid=\(wid) waited=\(Int(readTimeout))s assume-moved"))
        }
        return done.union(settled.changed).union(settled.unknown)
    }
}
