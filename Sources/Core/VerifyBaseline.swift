import Foundation

// VerifyBaseline — 验证器比对基准口径（spec §7，取代旧 §9.1 现势快照基准）。
// 缺省 = 当前拓扑最近一次恢复所用的预设；--preset <名称> = 当前拓扑下的指定预设；--snapshot <文件> 保留。
// 纯逻辑放 Core：VerifyCLI 只做枚举与报告渲染，基准选择在这里可测。

public enum VerifyBaseline: Equatable, Sendable {
    /// 当前拓扑最近恢复预设（缺省）
    case lastRestored
    /// 当前拓扑下按名称指定的预设
    case preset(name: String)
    /// 快照文件
    case snapshotFile(path: String)

    /// 参数 → 基准来源；--preset 与 --snapshot 至多给一个（互斥）
    public static func parse(_ args: [String]) throws -> VerifyBaseline {
        var source: VerifyBaseline?
        var i = args.startIndex
        while i < args.endIndex {
            let flag = args[i]
            guard flag == "--preset" || flag == "--snapshot" else {
                throw VerifyBaselineError.usage("未知参数 \(flag)")
            }
            guard args.indices.contains(i + 1) else { throw VerifyBaselineError.usage("\(flag) 缺少取值") }
            guard source == nil else { throw VerifyBaselineError.usage("--preset 与 --snapshot 只能给一个") }
            let value = args[i + 1]
            source = flag == "--preset" ? .preset(name: value) : .snapshotFile(path: value)
            i += 2
        }
        return source ?? .lastRestored
    }

    /// 预设类基准 → 当前拓扑下的预设。镜像中无拓扑（spec §3.3）、缺省基准下拓扑无预设或从未恢复 → noBaseline；
    /// --preset 名称在当前拓扑下查不到 → presetNotFound。snapshotFile 不经预设存储，由调用方自行读文件。
    public func resolvePreset(in store: PresetStore, topology: ObservedTopology) throws -> Preset {
        guard !topology.isMirrored else { throw VerifyBaselineError.noBaseline("镜像中，无当前拓扑") }
        let key = topology.identity.key
        let current = store.topology(key: key)
        switch self {
        case .lastRestored:
            guard let current, !current.presets.isEmpty else {
                throw VerifyBaselineError.noBaseline("当前拓扑 \(key) 没有预设")
            }
            guard let preset = current.presets.first(where: { $0.id == current.lastRestoredPresetID }) else {
                throw VerifyBaselineError.noBaseline("当前拓扑 \(key) 还没有恢复过预设")
            }
            return preset
        case .preset(let name):
            guard let preset = current?.preset(named: name) else {
                throw VerifyBaselineError.presetNotFound(name: name, available: current?.presets.map(\.name) ?? [])
            }
            return preset
        case .snapshotFile:
            throw VerifyBaselineError.usage("--snapshot 基准不经预设存储")
        }
    }
}

/// 基准错误：一律按用法错误退出（exit 2）
public enum VerifyBaselineError: Error, Equatable {
    case usage(String)
    /// 无比对基准
    case noBaseline(String)
    /// 当前拓扑下没有该名称的预设；available = 当前拓扑全部预设名
    case presetNotFound(name: String, available: [String])

    /// 人读说明（CLI 输出用）
    public var message: String {
        switch self {
        case .usage(let why):
            return why
        case .noBaseline(let why):
            return "无比对基准：\(why)；用 --preset <名称> 或 --snapshot <文件> 指定"
        case .presetNotFound(let name, let available):
            let list = available.isEmpty ? "（无）" : available.map { "「\($0)」" }.joined(separator: " ")
            return "当前拓扑下没有名为「\(name)」的预设；可用：\(list)"
        }
    }
}

extension PresetTopology {
    /// 按名称取预设：去首尾空白后精确比较（与 PresetStore 存名口径一致，同拓扑唯一）
    public func preset(named name: String) -> Preset? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return presets.first { $0.name == wanted }
    }
}
