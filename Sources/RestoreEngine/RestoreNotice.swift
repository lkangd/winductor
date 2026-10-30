import Core
import Foundation

// RestoreNotice.swift — 恢复通知结构（票 17，spec §8.5/§6.2）。
// 只产出结构（计数 + 降级附注 + 文案），系统通知投递归票 19（UNUserNotificationCenter 接线）。
// 降级附注来源：与 RestoreEngine/SpaceAdapter 共用的 [degrade] 日志收集 sink（DegradeCollectingLog）。

/// 恢复触发方式（通知措辞与 [trigger] 日志 trigger= 字段共用）
public enum RestoreTriggerKind: String, Equatable, Sendable {
    /// 自动触发（触发链走完）
    case auto
    /// 手动「立即恢复」（菜单 / DebugCLI restore-now）
    case manual
}

/// 完成通知（spec §8.5：成功/跳过/失败计数 + 降级附注；§6.3「结束发一条系统通知」）
public struct RestoreCompletionNotice: Equatable, Sendable {
    public let trigger: RestoreTriggerKind
    /// 条目级计数（RestoreReport 同口径：降级跳过不计失败，spec §6.1）
    public let okCount: Int
    public let skipCount: Int
    public let failCount: Int
    /// [degrade] 汇总的层名（如 ["Space 归属"]；空数组 = 无降级附注）
    public let degradedLayerNames: [String]
    /// 管线中止原因（无显示器 / 回滚快照写失败，RestoreEngineError）；nil = 正常完成
    public let failureDetail: String?

    public init(trigger: RestoreTriggerKind, okCount: Int, skipCount: Int, failCount: Int,
                degradedLayerNames: [String], failureDetail: String?) {
        self.trigger = trigger
        self.okCount = okCount
        self.skipCount = skipCount
        self.failCount = failCount
        self.degradedLayerNames = degradedLayerNames
        self.failureDetail = failureDetail
    }

    public var title: String {
        failureDetail == nil ? "恢复完成" : "恢复失败"
    }

    /// §8.5 措辞：恢复完成：12 窗口归位、1 跳过、0 失败；本次 Space 归属层失效（几何已恢复）
    public var body: String {
        if let failureDetail { return "恢复失败：\(failureDetail)" }
        var text = "恢复完成：\(okCount) 窗口归位、\(skipCount) 跳过、\(failCount) 失败"
        if !degradedLayerNames.isEmpty {
            text += "；本次 \(degradedLayerNames.joined(separator: "、")) 层失效（几何已恢复）"
        }
        return text
    }
}

/// 部分拓扑提示通知（spec §6.2「插回后仍少一块屏：不自动恢复，通知提示」，A5）
public struct PartialTopologyNotice: Equatable, Sendable {
    /// 当前屏幕数（提示语境）
    public let currentDisplayCount: Int

    public init(currentDisplayCount: Int) {
        self.currentDisplayCount = currentDisplayCount
    }

    public var title: String { "未能自动恢复" }

    /// 文案照 09 通知风格；指向菜单「立即恢复」best-effort 单屏恢复入口（03 #8）
    public var body: String {
        "当前屏幕集合与任何快照都不完全一致，未自动恢复；可用菜单「立即恢复」按当前屏幕 best-effort 恢复。"
    }
}

/// 恢复通知（票 19 投递接缝的载荷类型）
public enum RestoreNotice: Equatable, Sendable {
    case completed(RestoreCompletionNotice)
    case partialTopology(PartialTopologyNotice)

    /// 日志 kind= 字段用（短横线形）
    public var kind: String {
        switch self {
        case .completed: return "completed"
        case .partialTopology: return "partial-topology"
        }
    }

    public var title: String {
        switch self {
        case .completed(let notice): return notice.title
        case .partialTopology(let notice): return notice.title
        }
    }

    public var body: String {
        switch self {
        case .completed(let notice): return notice.body
        case .partialTopology(let notice): return notice.body
        }
    }
}

/// 降级层号 → 通知附注层名（§8.5 能力状态行同款词汇：Space 归属、最小化窗口归位）
public enum RestoreNoticeLayers {
    public static func name(forDegradeLayer layer: Int) -> String {
        switch layer {
        case 2: return "Space 归属"
        case 3: return "全屏状态"
        case 4: return "最小化窗口归位"
        default: return "L\(layer)"
        }
    }
}

/// [degrade] 日志收集 sink：转发全部行到内层 sink，同时抽取 "[degrade] layer=L<n>" 行的层号。
/// 票 19 生产接线：同一个实例既传给 TriggerChain（degradeCollector:）也传给
/// RestoreEngine/SpaceAdapter（log:），恢复期所有降级行即被汇总进完成通知附注。
public final class DegradeCollectingLog: LogWriting, @unchecked Sendable {
    private let inner: LogWriting?
    private let lock = NSLock()
    private var layers: [Int] = []

    public init(inner: LogWriting? = nil) {
        self.inner = inner
    }

    public func write(_ line: String) {
        if let layer = Self.degradeLayer(in: line) {
            lock.lock()
            layers.append(layer)
            lock.unlock()
        }
        inner?.write(line)
    }

    /// 取走已收集的降级层号（取后清空；恢复结束后调一次）
    public func drainDegradeLayers() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        let out = layers
        layers = []
        return out
    }

    /// 解析 "[degrade] layer=L<n> …" 行（spec §10.4 降级行格式）；非降级行返回 nil
    public static func degradeLayer(in line: String) -> Int? {
        let prefix = "[degrade] layer=L"
        guard line.hasPrefix(prefix) else { return nil }
        let digits = line.dropFirst(prefix.count).prefix(while: \.isNumber)
        guard let layer = Int(digits) else { return nil }
        return layer
    }
}
