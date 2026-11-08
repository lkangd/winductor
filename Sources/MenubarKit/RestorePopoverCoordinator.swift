import Core
import Foundation
import RestoreEngine

// RestorePopoverCoordinator.swift — 触发链判定结果（TriggerChain.onOutcome）→ 恢复提示 / 自动恢复告知 popover
// （display-presets spec §6.2/§6.3）。判定结果在调用线程转成内容（含实时 Space 读取），状态机与渲染在主线程。
// 规则在 RestorePopoverState；本类只接线：渲染器、触发链手动恢复、撤销管线、告知到期调度。

/// popover 渲染接缝（生产：StatusItemPopoverPresenter 锚定状态项按钮；测试：假件记录呈现）
public protocol RestorePopoverRendering: AnyObject {
    /// 用户操作回传（渲染器在主线程调用）
    var onEvent: ((RestorePopoverEvent) -> Void)? { get set }
    /// 主线程调用；.hidden = 收起
    func render(_ presentation: RestorePopoverPresentation)
}

public final class RestorePopoverCoordinator {
    /// 告知显示时长（§6.3「数秒后自动消失」）
    public static let noticeDuration: TimeInterval = 6

    private let renderer: RestorePopoverRendering?
    private let presets: PresetStore
    private let currentSpaces: () -> [SpaceEntry]?
    private let restorePreset: (_ presetID: String, _ topologyKey: String) -> ManualRestoreRejection?
    private let undo: () -> Void
    private let scheduleAfter: (TimeInterval, @escaping () -> Void) -> Void
    private let log: LogWriting?
    private var state = RestorePopoverState()

    /// - Parameters:
    ///   - currentSpaces: 实时受管 Space 清单（Space 不足提示用；nil = 读不到，不提示）
    ///   - restorePreset: 提示「恢复」→ 触发链 restorePresetAsync（经菜单协调器：被拒时告知用户）；返回 nil = 已受理
    ///   - undo: 告知「撤销」→ 菜单同款撤销管线（离主线程、两段式通知）
    ///   - scheduleAfter: 告知到期调度（回调须在主线程）
    public init(renderer: RestorePopoverRendering?,
                presets: PresetStore,
                currentSpaces: @escaping () -> [SpaceEntry]?,
                restorePreset: @escaping (_ presetID: String, _ topologyKey: String) -> ManualRestoreRejection?,
                undo: @escaping () -> Void,
                scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                },
                log: LogWriting? = nil) {
        self.renderer = renderer
        self.presets = presets
        self.currentSpaces = currentSpaces
        self.restorePreset = restorePreset
        self.undo = undo
        self.scheduleAfter = scheduleAfter
        self.log = log
        renderer?.onEvent = { [weak self] event in self?.send(event) }
    }

    /// 判定结果入口（任意线程：触发链调度队列 / 恢复队列）
    public func handle(outcome: TriggerOutcome) {
        let event: RestorePopoverEvent
        switch outcome {
        case .promptNeeded(let topology):
            event = promptEvent(for: topology)
        case .autoRestored(let restored):
            event = .autoRestored(AutoRestoreNoticeContent.make(restored))
        case .dismissPrompt, .topologyChanging:
            // 拓扑再变（§6.2）：事件一到即收起旧拓扑的提示/告知，新判定结果到达后再替换
            event = .dismiss
        }
        Self.runOnMain { [weak self] in self?.send(event) }
    }

    /// 状态机推进 + 渲染 + 执行副作用（主线程）
    func send(_ event: RestorePopoverEvent) {
        let before = state.presentation
        let effects = state.apply(event)
        if state.presentation != before {
            log?.write("[popover] action=render kind=\(Self.kind(of: state.presentation))")
            renderer?.render(state.presentation)
        }
        effects.forEach { perform($0, after: before) }
    }

    /// - after: 产出该副作用之前的呈现（「恢复」被拒时据此弹回原提示）
    private func perform(_ effect: RestorePopoverEffect, after previous: RestorePopoverPresentation) {
        switch effect {
        case .restore(let presetID, let topologyKey):
            log?.write("[popover] action=restore preset=\(presetID) topology=\(topologyKey)")
            guard let rejection = restorePreset(presetID, topologyKey) else { return }
            log?.write("[popover] action=restore result=rejected detail=\(rejection)")
            // 恢复进行中被拒：选择仍有效，弹回同一提示（含所选预设）供稍后再点（§6.2 选择不丢失）；
            // 拓扑已变 / 镜像中 / 预设已删：提示已过期，不弹回（告知由注入方投递）
            if rejection == .restoreInProgress, case .prompt(let content) = previous {
                send(.promptNeeded(content))
            }
        case .undo:
            log?.write("[popover] action=undo")
            undo()
        case .openPrompt(let topologyKey):
            guard let topology = presets.topology(key: topologyKey) else { return send(.dismiss) }
            send(promptEvent(for: topology))
        case .scheduleNoticeExpiry(let generation):
            scheduleAfter(Self.noticeDuration) { [weak self] in self?.send(.noticeExpired(generation: generation)) }
        }
    }

    /// 拓扑 → 提示内容；无预设（判定后被删光）→ 收起
    private func promptEvent(for topology: PresetTopology) -> RestorePopoverEvent {
        guard let content = RestorePromptContent.make(topology: topology, currentSpaces: currentSpaces()) else {
            return .dismiss
        }
        return .promptNeeded(content)
    }

    private static func kind(of presentation: RestorePopoverPresentation) -> String {
        switch presentation {
        case .hidden: return "hidden"
        case .prompt: return "prompt"
        case .notice: return "notice"
        }
    }

    private static func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
