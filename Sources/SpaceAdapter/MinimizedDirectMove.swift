import Core
import Foundation

// MinimizedDirectMove.swift — SpaceAdapter 小增量（票 15，新增文件理由见票 15 报告）：
// 最小化窗口的「直接桥接」尝试（spec §6.5：实测最小化状态可直接桥接则省去取消/重最小化首尾）。
// 与 moveWindowsToSpace 的关键差别：失败不做运行时 no-op 标记（不写 runtimeNoOpLayers）——
// 最小化窗直移失败只说明「该窗不能直移」，不应毒化 L2 桥接层（进程内不可逆），
// 否则 §6.5 回退路径（取消最小化 → 桥接 → 重最小化）会被 layerUnavailable 卡死。
extension SpaceAdapter {
    /// 桥接 settle 等待（spike 实测 1.2s 足够 WindowServer 结算，与 moveWindowsToSpace 同值）
    private static let minimizedSettleSeconds: TimeInterval = 1.2

    /// 最小化窗口直接桥接尝试；返回 true = 归属实际变更（或已在目标 Space）；
    /// false = perform 后归属未变更（不标记层失效，调用方走回退路径）。
    /// - Throws: `SpaceAdapterError.layerUnavailable(.bridge)`（探针未过 / 已失效 / FORCE_DEGRADED）
    @discardableResult
    public func tryMoveMinimized(windowID wid: UInt32, spaceID: Int64) throws -> Bool {
        guard isLayerAvailable(.bridge) else { throw SpaceAdapterError.layerUnavailable(.bridge) }
        let before = try spaceIDs(windowID: wid)
        // 已在目标 Space：无事可做
        if before == [spaceID] { return true }
        // 限时执行（同 moveWindowsToSpace；超时按未迁移处理，调用方走 §6.5 回退保持最小化）
        switch SpaceAdapter.performBridgedMoveBounded([wid], spaceID: UInt64(spaceID),
                                                      timeout: SpaceAdapter.bridgeOpTimeoutSeconds) {
        case .completed(let issue):
            if let issue { throw SpaceAdapterError.bridgedOpFailed(issue) }
        case .timedOut:
            throw SpaceAdapterError.bridgedOpFailed("bridge-timeout")
        }
        Thread.sleep(forTimeInterval: Self.minimizedSettleSeconds)
        return try spaceIDs(windowID: wid) != before
    }
}
