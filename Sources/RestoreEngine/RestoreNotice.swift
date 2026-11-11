import Core
import Foundation

// RestoreNotice.swift — 恢复通知结构（票 17，spec §8.5）+ 触发链判定结果（display-presets 票 04，spec §5.1）。
// 只产出结构（计数 + 降级附注 + 文案），系统通知投递归票 19（UNUserNotificationCenter 接线）。
// 降级附注来源：与 RestoreEngine/SpaceAdapter 共用的 [degrade] 日志收集 sink（DegradeCollectingLog）。

/// 恢复触发方式（通知措辞与 [trigger] 日志 trigger= 字段共用）
public enum RestoreTriggerKind: String, Equatable, Sendable {
    /// 自动触发（触发链走完）
    case auto
    /// 手动恢复（菜单「恢复预设 ▸」/ 恢复提示 / 主窗口）
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
    /// 卡在其他屏全屏 Space 而跳过的全屏应用数（RestoreReport 同名字段；display-presets 票 17）
    public let fullscreenOnOtherDisplayCount: Int

    public init(trigger: RestoreTriggerKind, okCount: Int, skipCount: Int, failCount: Int,
                degradedLayerNames: [String], failureDetail: String?,
                fullscreenOnOtherDisplayCount: Int = 0) {
        self.trigger = trigger
        self.okCount = okCount
        self.skipCount = skipCount
        self.failCount = failCount
        self.degradedLayerNames = degradedLayerNames
        self.failureDetail = failureDetail
        self.fullscreenOnOtherDisplayCount = fullscreenOnOtherDisplayCount
    }

    public var title: String {
        failureDetail == nil ? "恢复完成" : "恢复失败"
    }

    /// §8.5 措辞：恢复完成：12 窗口归位、1 跳过、0 失败；本次 Space 归属层失效（几何已恢复）
    public var body: String {
        if let failureDetail { return "恢复失败：\(failureDetail)" }
        return "恢复完成：" + countsText
    }

    /// 计数 + 降级附注（不带「恢复完成：」前缀）
    public var countsText: String {
        guard let degradeNote else { return tallyText }
        return tallyText + "；" + degradeNote
    }

    /// 仅计数：12 窗口归位、1 跳过、0 失败（自动恢复告知 popover 与附注分行呈现，display-presets 票 14）
    public var tallyText: String {
        "\(okCount) 窗口归位、\(skipCount) 跳过、\(failCount) 失败"
    }

    /// 附注：降级层（本次 Space 归属层失效（几何已恢复））+ 他屏全屏可操作提示（票 17），「；」相连；都没有 → nil
    public var degradeNote: String? {
        var notes: [String] = []
        if !degradedLayerNames.isEmpty {
            notes.append("本次 \(degradedLayerNames.joined(separator: "、"))层失效（几何已恢复）")
        }
        if fullscreenOnOtherDisplayCount > 0 {
            // 后台退出全屏不可达（§5.2）：用户在那块屏退出全屏后再恢复一次即可归位
            notes.append("\(fullscreenOnOtherDisplayCount) 个全屏应用在其他屏幕上，退出全屏后可再次恢复")
        }
        return notes.isEmpty ? nil : notes.joined(separator: "；")
    }
}

/// 恢复通知（系统通知投递接缝的载荷类型；display-presets 票 04 起只剩完成通知，部分拓扑通知随 spec §5.1 删除）
public enum RestoreNotice: Equatable, Sendable {
    case completed(RestoreCompletionNotice)

    /// 日志 kind= 字段用（短横线形）
    public var kind: String {
        switch self {
        case .completed: return "completed"
        }
    }

    public var title: String {
        switch self {
        case .completed(let notice): return notice.title
        }
    }

    public var body: String {
        switch self {
        case .completed(let notice): return notice.body
        }
    }

    /// 完成通知的触发方式
    public var trigger: RestoreTriggerKind? {
        switch self {
        case .completed(let notice): return notice.trigger
        }
    }
}

/// 触发链判定结果（display-presets spec §5.1 判定表 → 菜单栏 UI；display-presets 票 05 popover 挂 TriggerChain.onOutcome）。
/// 只在拓扑变化后产出（拓扑未变的事件、应用启动、被中止的恢复轮次均不产出）：
/// 每轮变化先发 topologyChanging（事件一到），稳定后再发判定结果。
public enum TriggerOutcome: Equatable, Sendable {
    /// 拓扑变化事件已到达、尚未判定（防抖/稳定判据进行中）：开着的恢复提示属于旧拓扑，即刻收起
    /// （§6.2「拓扑再变：替换内容」，防旧提示在防抖期间仍可点；display-presets 票 05 评审修复）
    case topologyChanging
    /// 有自动预设：已直接恢复（§6.3 自动恢复告知；含失败——notice.failureDetail 非 nil）
    case autoRestored(AutoRestoredOutcome)
    /// 有预设但无自动：请求弹出 / 替换恢复提示（§6.2）；载荷 = 判定时刻的拓扑与预设列表
    case promptNeeded(PresetTopology)
    /// 新拓扑无预设 / 镜像中 / 未就绪：不恢复不弹，若恢复提示开着则收起（§6.2「新拓扑无预设则收起」）
    case dismissPrompt

    /// 日志 result= 字段用
    public var kind: String {
        switch self {
        case .topologyChanging: return "topology-changing"
        case .autoRestored: return "auto-restored"
        case .promptNeeded: return "prompt"
        case .dismissPrompt: return "dismiss-prompt"
        }
    }
}

/// 手动恢复（恢复提示「恢复」/ 恢复预设子菜单 / 主窗口）被触发链拒绝的原因（display-presets 票 04 评审修复：
/// 被拒不再静默，调用方据此告知用户）
public enum ManualRestoreRejection: Error, Equatable, Sendable {
    /// 辅助功能与屏幕录制权限尚未齐备
    case notReady
    /// 所选预设不属于当前拓扑（入口打开后屏幕排列变了；spec §5.2 仅当前拓扑）
    case topologyChanged
    /// 镜像中整体禁用（spec §3.3）
    case mirrored
    /// 预设已不存在（入口打开后被删）
    case presetMissing
    /// 恢复/撤销管线进行中
    case restoreInProgress
}

/// 自动恢复结果（§6.3 告知所需：预设名、计数与降级附注、是否附「改用其他预设…」）
public struct AutoRestoredOutcome: Equatable, Sendable {
    public let topologyKey: String
    public let presetID: String
    public let presetName: String
    /// 计数 + 降级附注（口径同手动恢复完成通知）
    public let notice: RestoreCompletionNotice
    /// 拓扑下还有其他预设（告知附「改用其他预设…」）
    public let hasOtherPresets: Bool

    public init(topologyKey: String, presetID: String, presetName: String,
                notice: RestoreCompletionNotice, hasOtherPresets: Bool) {
        self.topologyKey = topologyKey
        self.presetID = presetID
        self.presetName = presetName
        self.notice = notice
        self.hasOtherPresets = hasOtherPresets
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
