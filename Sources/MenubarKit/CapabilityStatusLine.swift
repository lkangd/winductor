import RestoreEngine
import SpaceAdapter

// CapabilityStatusLine.swift — 能力状态行（票 19，spec §8.5「降级呈现 = 能力状态行 + 通知附注」）。
// 数据源 = SpaceAdapter.probeLayers()（启动探测 + FORCE_DEGRADED + 运行时 no-op 同一口径）；
// 文案：「能力状态：全部可用」或「能力状态：以下恢复层不可用：<层名逐层列出>（详见日志）」。
// 层名与恢复通知附注共用 RestoreNoticeLayers 词汇（Space 归属／全屏状态／最小化窗口归位）。

/// 单层能力状态（MenubarKit 内的接缝值类型；生产由 SpaceAdapterCapabilityProbe 填充，测试用假值）
public struct CapabilityLayerStatus: Equatable, Sendable {
    public let layerNumber: Int
    public let displayName: String
    public let available: Bool

    public init(layerNumber: Int, displayName: String, available: Bool) {
        self.layerNumber = layerNumber
        self.displayName = displayName
        self.available = available
    }

    /// 层号 → 层名（§8.5 词汇，与 RestoreNoticeLayers 通知附注同源）
    public static func name(forLayerNumber layerNumber: Int) -> String {
        RestoreNoticeLayers.name(forDegradeLayer: layerNumber)
    }
}

public enum CapabilityStatusLine {
    /// 能力状态行标题（spec §8.5 逐字措辞；不可用层按传入顺序逐层列出、顿号连接）
    public static func title(for layers: [CapabilityLayerStatus]) -> String {
        let unavailable = layers.filter { !$0.available }
        guard !unavailable.isEmpty else { return "能力状态：全部可用" }
        let names = unavailable.map(\.displayName).joined(separator: "、")
        return "能力状态：以下恢复层不可用：\(names)（详见日志）"
    }
}

/// 生产探针：包装票 13 SpaceAdapter 的启动探测（app 入口 target 不能 import SpaceAdapter，
/// 经 MenubarKit（RestoreEngine 传递依赖）在此适配为 CapabilityLayerStatus）
public struct SpaceAdapterCapabilityProbe {
    private let adapter: SpaceAdapter

    public init(adapter: SpaceAdapter) {
        self.adapter = adapter
    }

    /// 全部层探测结果（菜单能力状态行数据源）
    public func probe() -> [CapabilityLayerStatus] {
        adapter.probeLayers().map { probe in
            CapabilityLayerStatus(
                layerNumber: probe.layer.layerNumber,
                displayName: CapabilityLayerStatus.name(forLayerNumber: probe.layer.layerNumber),
                available: probe.available)
        }
    }
}
