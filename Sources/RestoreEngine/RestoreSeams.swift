import AXFacade
import Core
import CoreGraphics
import Foundation
import SpaceAdapter

// RestoreSeams.swift — 恢复管线的注入接缝（票 14）。
// 生产侧 = SpaceAdapter / AxFacade 的薄包装；测试侧 = fake 注入（Tests/RestoreEngineTests/Fakes.swift）。
// 不改 SpaceAdapter / AxFacade 既有公开签名（票 13 拥有，禁改）。

/// 恢复管线需要的 Space 能力（spec §6.8 L2 桥接 + Space 枚举；Core/Seams.SpaceProviding 的超集）
public protocol SpaceBridge: SpaceProviding, Sendable {
    /// L2 桥接层可用（探针通过、未 no-op 失效、未 FORCE_DEGRADED，spec §10.2）
    func isBridgeAvailable() -> Bool

    /// 桥接移窗（屏 + Space 一步到位）；返回 false = perform 后归属未变更（no-op，适配器已记 [degrade]）
    @discardableResult
    func moveWindowsToSpace(windowIDs: [UInt32], spaceID: Int64) throws -> Bool
}

/// SpaceBridge 生产实现：包装票 13 的 SpaceAdapter
public struct SpaceAdapterBridge: SpaceBridge {
    private let adapter: SpaceAdapter

    public init(_ adapter: SpaceAdapter) { self.adapter = adapter }

    public func managedSpaces() throws -> [SpaceEntry] { try adapter.managedSpaces() }
    public func spaceIDsByWindowID() throws -> [UInt32: Int64] { try adapter.spaceIDsByWindowID() }
    public func isBridgeAvailable() -> Bool { adapter.isLayerAvailable(.bridge) }

    @discardableResult
    public func moveWindowsToSpace(windowIDs wids: [UInt32], spaceID: Int64) throws -> Bool {
        try adapter.moveWindowsToSpace(windowIDs: wids, spaceID: spaceID)
    }
}

/// AX 几何写接缝（spec §6.8 L1 摆位）。「AX 权限不足」等失败以抛错表达，管线按 result=fail 记日志。
public protocol WindowGeometryWriting: Sendable {
    func apply(windowID: UInt32, position: CGPoint, size: CGSize) throws
}

/// WindowGeometryWriting 生产实现：经 AxFacade 反查 AX 元素后写 AXPosition/AXSize。
/// 无辅助功能授权时 setPosition 抛 AXFacadeError.apiDisabled（本票验收行为之一）。
public struct AXGeometryWriter: WindowGeometryWriting {
    public init() {}

    public func apply(windowID: UInt32, position: CGPoint, size: CGSize) throws {
        guard let element = AXFacade.findWindow(withWindowID: windowID) else {
            throw AXFacadeError.elementInvalid
        }
        try AXFacade.setPosition(element, position)
        try AXFacade.setSize(element, size)
    }
}
