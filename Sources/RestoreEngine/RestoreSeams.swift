import AXFacade
import ApplicationServices
import Core
import CoreGraphics
import Foundation
import SpaceAdapter

// RestoreSeams.swift — 恢复管线的注入接缝（票 14；L3/L4 写接缝与层探针票 15 增量）。
// 生产侧 = SpaceAdapter / AxFacade 的薄包装；测试侧 = fake 注入（Tests/RestoreEngineTests/Fakes.swift）。
// 不改 SpaceAdapter / AxFacade 既有公开签名（票 13 拥有，禁改）。

/// 恢复管线需要的 Space 能力（spec §6.8 L2 桥接 + Space 枚举 + 降级阶梯层探针；Core/Seams.SpaceProviding 的超集）
public protocol SpaceBridge: SpaceProviding, Sendable {
    /// 降级阶梯层可用性（探针 + FORCE_DEGRADED + 运行时 no-op，spec §6.1/§10.2）。
    /// L2 = .bridge；L3 = .fullscreen；L4 = .minimized（票 15）
    func isLayerAvailable(_ layer: SpaceLayer) -> Bool

    /// 桥接移窗（屏 + Space 一步到位）；返回 false = perform 后归属未变更（no-op，适配器已记 [degrade]）
    @discardableResult
    func moveWindowsToSpace(windowIDs: [UInt32], spaceID: Int64) throws -> Bool

    /// L4 最小化窗口「直接桥接」尝试（票 15，spec §6.5：实测可直移则省去取消/重最小化首尾）。
    /// 与 moveWindowsToSpace 的差别：失败不做运行时 no-op 标记（不毒化 L2 层，回退路径仍可用）。
    /// 票 16：同目标 Space 的一批窗一次桥接 + 一次轮询结算；返回归属已变更（或已在目标）的窗，
    /// 不在其中 = perform 后归属未变更（调用方逐窗回退）
    @discardableResult
    func tryMoveMinimized(windowIDs: [UInt32], spaceID: Int64) throws -> Set<UInt32>

    /// 新一轮恢复/撤销开始（display-presets 票 12）：清除上一轮留下的运行时 no-op 失效标记。
    /// 桥接 no-op 的失效作用域 = 本轮（本轮剩余项照旧快速跳过），下一轮重新可用；探针 / FORCE_DEGRADED 不受影响
    func beginRestoreRound()

    /// 各屏活跃 Space id 集合（后台窗精准判定：窗不在任一活跃 Space = AX 不可见）。
    /// 协议 requirement（extension 方法对 existential 静态分派到默认实现，witness 不生效——实测教训）
    func activeSpaceIDs() throws -> Set<Int64>
}

public extension SpaceBridge {
    /// L2 速查（≡ isLayerAvailable(.bridge)，票 14 原口径保留）
    func isBridgeAvailable() -> Bool { isLayerAvailable(.bridge) }
}

/// SpaceBridge 生产实现：包装票 13 的 SpaceAdapter
public struct SpaceAdapterBridge: SpaceBridge {
    private let adapter: SpaceAdapter

    public init(_ adapter: SpaceAdapter) { self.adapter = adapter }

    public func managedSpaces() throws -> [SpaceEntry] { try adapter.managedSpaces() }
    public func spaceIDsByWindowID() throws -> [UInt32: Int64] { try adapter.spaceIDsByWindowID() }
    public func orderedOutWindowIDs(among windowIDs: [UInt32]) -> Set<UInt32>? {
        adapter.orderedOutWindowIDs(among: windowIDs)
    }
    public func isLayerAvailable(_ layer: SpaceLayer) -> Bool { adapter.isLayerAvailable(layer) }
    public func activeSpaceIDs() throws -> Set<Int64> { Set(try adapter.currentSpaceIDs().values) }
    public func beginRestoreRound() { adapter.clearRuntimeNoOp() }

    @discardableResult
    public func moveWindowsToSpace(windowIDs wids: [UInt32], spaceID: Int64) throws -> Bool {
        try adapter.moveWindowsToSpace(windowIDs: wids, spaceID: spaceID)
    }

    @discardableResult
    public func tryMoveMinimized(windowIDs wids: [UInt32], spaceID: Int64) throws -> Set<UInt32> {
        try adapter.tryMoveMinimized(windowIDs: wids, spaceID: spaceID)
    }
}

/// AX 几何写接缝（spec §6.8 L1 摆位）。「AX 权限不足」等写失败以抛错表达，管线按 result=fail 记日志。
public protocol WindowGeometryWriting: Sendable {
    /// L1 批次开始前调用一次：生产实现一次遍历建 windowID → AX 元素索引（实测缺陷修复：
    /// 逐窗全量遍历 AX 树使 44 窗耗时 105s；一次建索引后仅需查表 + 两次属性写）。
    /// 默认空实现兼容模拟接缝/测试假体。
    func prepare(windowIDs: [UInt32])
    func apply(windowID: UInt32, position: CGPoint, size: CGSize) throws
}

public extension WindowGeometryWriting {
    func prepare(windowIDs: [UInt32]) {}
}

/// WindowGeometryWriting 生产实现：预建 windowID → AX 元素索引后写 AXPosition/AXSize。
/// 无辅助功能授权时 setPosition 抛 AXFacadeError.apiDisabled（本票验收行为之一）。
public final class AXGeometryWriter: WindowGeometryWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var index: [UInt32: AXUIElement] = [:]
    /// prepare 时确认「所属 app 的 AX 窗口表已完整读到、却不含它」的窗（非 AX 窗口，写必失败）
    private var notAXWindows = Set<UInt32>()

    public init() {}

    /// 只对目标窗的 CG owner pid 建 windowID → AX 元素索引（实测：逐窗遍历 44 窗耗时 105s；
    /// 全量 app 遍历被无响应 helper 进程拖到 ~4.7s）；每个 app 元素设 1.5s 消息超时，防单 app 卡顿拖垮整轮。
    /// CG 一个 owner 都查不到时回退全量遍历；个别未命中的窗由 apply 逐窗反查兜底
    public func prepare(windowIDs: [UInt32]) {
        let owners = AXFacade.owners(of: windowIDs)
        let pids = Set(owners.values)
        let built = AXFacade.makeWindowIndex(pids: pids.isEmpty && !windowIDs.isEmpty ? nil : pids,
                                             timeoutPerApp: 1.5)
        let missing = Self.notAXWindows(owners: owners, index: Set(built.windows.keys), indexedPIDs: built.indexedPIDs)
        lock.lock()
        index = built.windows
        notAXWindows = missing
        lock.unlock()
    }

    /// 所属 app 已成功建索引却不在索引里的窗（纯函数，单测用）
    static func notAXWindows(owners: [UInt32: pid_t], index: Set<UInt32>, indexedPIDs: Set<pid_t>) -> Set<UInt32> {
        Set(owners.compactMap { wid, pid in indexedPIDs.contains(pid) && !index.contains(wid) ? wid : nil })
    }

    public func apply(windowID: UInt32, position: CGPoint, size: CGSize) throws {
        lock.lock()
        let element = index[windowID]
        let notAX = notAXWindows.contains(windowID)
        lock.unlock()
        // 非 AX 窗口：反查同一张 AXWindows 表也找不到，只会白等到限时（实测 L1 尾部 1.5s 全由它们构成）
        if notAX { throw RestoreEngineError.notAXWindow }
        guard let element else {
            // 索引未命中（prepare 后新出现的窗）：回退逐树反查，保持原语义
            guard let fallback = AXFacade.findWindow(withWindowID: windowID) else {
                throw AXFacadeError.elementInvalid
            }
            try AXFacade.setPosition(fallback, position)
            try AXFacade.setSize(fallback, size)
            return
        }
        do {
            try AXFacade.setPosition(element, position)
            try AXFacade.setSize(element, size)
        } catch AXFacadeError.elementInvalid {
            // 索引过期（恢复中窗口被 macOS/用户移动 → AX 元素句柄失效，实测 4.6s 超时 elementInvalid）：
            // 反查重建元素重试一次（单次，非循环），成功后刷新索引
            guard let fresh = AXFacade.findWindow(withWindowID: windowID) else {
                throw AXFacadeError.elementInvalid
            }
            try AXFacade.setPosition(fresh, position)
            try AXFacade.setSize(fresh, size)
            lock.lock()
            index[windowID] = fresh
            lock.unlock()
        }
    }
}

/// L3 全屏写接缝（票 15，spec §6.8 全屏最后：目标屏就位后 AXFullScreen=true）。
/// 全屏 Space(type=4) 在目标显示器后台创建并接管窗口（05 #4）；「后台退出全屏」约束只咬撤销（票 16）。
public protocol WindowFullScreenWriting: Sendable {
    /// true = 进入全屏（恢复）；false = 退出全屏（两段式撤销第一段用，票 16）
    func setFullScreen(windowID: UInt32, _ fullScreen: Bool) throws
}

/// L4 最小化写接缝（票 15，spec §6.5：取消最小化 → 桥接 → 重新最小化的首尾步骤）
public protocol WindowMinimizeWriting: Sendable {
    func setMinimized(windowID: UInt32, _ minimized: Bool) throws
}

/// WindowFullScreenWriting 生产实现：经 AxFacade 反查 AX 元素后写 AXFullScreen（票 13 已有写入口）。
/// 无辅助功能授权时抛 AXFacadeError.apiDisabled，管线按 result=fail 记日志。
public struct AXFullScreenWriter: WindowFullScreenWriting {
    public init() {}

    public func setFullScreen(windowID wid: UInt32, _ fullScreen: Bool) throws {
        guard let element = AXFacade.findWindow(withWindowID: wid) else {
            throw AXFacadeError.elementInvalid
        }
        try AXFacade.setFullScreen(element, fullScreen)
    }
}

/// WindowMinimizeWriting 生产实现：经 AxFacade 反查 AX 元素后写 AXMinimized。
public struct AXMinimizeWriter: WindowMinimizeWriting {
    public init() {}

    public func setMinimized(windowID wid: UInt32, _ minimized: Bool) throws {
        guard let element = AXFacade.findWindow(withWindowID: wid) else {
            throw AXFacadeError.elementInvalid
        }
        try AXFacade.setMinimized(element, minimized)
    }
}
