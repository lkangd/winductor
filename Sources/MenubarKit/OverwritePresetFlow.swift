import AppKit
import Core
import SnapshotEngine

// OverwritePresetFlow.swift — 「用当前布局覆盖」（display-presets spec §4.2/§4.3，票 07）。
// 入口两处共用本流程：预设管理窗口的预设行、菜单「恢复预设 ▸」子菜单的「用当前布局覆盖 ▸」。
// 流程：可用性门（与保存同口径：未就绪 / 镜像中 / 恢复进行中 → 禁用）→ 确认框（覆盖不可撤回，带预设名）
// → 一次性拍快照（SnapshotEngine.capture，离主线程）→ 仅当拍快照时的拓扑 = 预设所属拓扑才写
// （spec「仅当前拓扑」：确认期间拓扑变了也拒绝）→ PresetStore.overwritePreset（保留名称与自动标记，更新快照与保存时间）。
// 失败（拓扑已变 / 拍快照或写盘失败）经 notifier 投「覆盖预设失败」。

/// 覆盖确认框接缝（生产：AlertPresetOverwriteConfirm；测试：脚本假件）
public protocol PresetOverwriteConfirming: AnyObject {
    /// 返回 true = 确认覆盖
    func confirmOverwrite(presetName: String) -> Bool
}

/// 一次覆盖流程的结果
public enum OverwritePresetOutcome: Equatable {
    case overwritten(name: String, topologyKey: String)
    /// 用户在确认框取消
    case cancelled
    /// 禁用态（入口本应置灰；拍快照时才发现的镜像/恢复也归此）
    case unavailable(SavePresetAvailability)
    /// 拍快照时的拓扑不是预设所属拓扑（已通知用户）
    case topologyChanged
    /// 预设不存在、拍快照或写盘失败（已通知用户）
    case failed(String)
}

public final class OverwritePresetFlow {
    private let store: PresetStore
    private let capture: () throws -> LayoutCapture
    private let availabilityCheck: () -> SavePresetAvailability
    private let confirm: PresetOverwriteConfirming
    private let notifier: SystemNotifying?
    private let log: LogWriting?
    private let captureExecutor: (@escaping () -> Void) -> Void
    private let mainExecutor: (@escaping () -> Void) -> Void
    /// runAsync 一轮进行中（确认 → 拍快照 → 写盘）；只在主线程读写
    private var isRunning = false

    /// - Parameters:
    ///   - capture: 一次性拍快照（生产 = SnapshotEngine.capture）
    ///   - availability: 可用性门（生产 = SavePresetFlow.availability，保存与覆盖同口径）
    ///   - captureExecutor / mainExecutor: runAsync 的两段执行器（生产 = 全局队列 / 主队列；测试手动推进）
    public init(store: PresetStore,
                capture: @escaping () throws -> LayoutCapture,
                availability: @escaping () -> SavePresetAvailability,
                confirm: PresetOverwriteConfirming,
                notifier: SystemNotifying? = nil,
                log: LogWriting? = nil,
                captureExecutor: @escaping (@escaping () -> Void) -> Void = { work in
                    DispatchQueue.global(qos: .userInitiated).async(execute: work)
                },
                mainExecutor: @escaping (@escaping () -> Void) -> Void = { work in
                    DispatchQueue.main.async(execute: work)
                }) {
        self.store = store
        self.capture = capture
        self.availabilityCheck = availability
        self.confirm = confirm
        self.notifier = notifier
        self.log = log
        self.captureExecutor = captureExecutor
        self.mainExecutor = mainExecutor
    }

    /// 覆盖入口当前可用性（入口构建时调用；与「保存当前布局为预设…」同口径）
    public func availability() -> SavePresetAvailability {
        availabilityCheck()
    }

    /// 走一遍覆盖流程（同步：确认、拍快照、写盘都在调用线程；UI 路径用 runAsync）
    @discardableResult
    public func run(presetID: String, topologyKey: String) -> OverwritePresetOutcome {
        switch prepare(presetID: presetID, topologyKey: topologyKey) {
        case .finished(let outcome): return outcome
        case .confirmed:
            return write(captureLayout(), presetID: presetID, topologyKey: topologyKey)
        }
    }

    /// UI 路径（主线程调用）：门与确认框在调用线程；拍快照经 captureExecutor 离开主线程，
    /// 写盘与 completion 经 mainExecutor 回到主线程。上一轮未结束时不受理，返回 false 且不回调。
    @discardableResult
    public func runAsync(presetID: String, topologyKey: String,
                         completion: @escaping (OverwritePresetOutcome) -> Void) -> Bool {
        guard !isRunning else {
            log?.write("[preset] action=overwrite result=skip detail=in-flight")
            return false
        }
        isRunning = true
        switch prepare(presetID: presetID, topologyKey: topologyKey) {
        case .finished(let outcome):
            isRunning = false
            completion(outcome)
        case .confirmed:
            captureExecutor { [self] in
                let captured = captureLayout()
                mainExecutor { [self] in
                    let outcome = write(captured, presetID: presetID, topologyKey: topologyKey)
                    isRunning = false
                    completion(outcome)
                }
            }
        }
        return true
    }

    // MARK: 步骤

    private enum Preparation {
        case confirmed
        case finished(OverwritePresetOutcome)
    }

    /// 门 → 查预设名 → 确认框
    private func prepare(presetID: String, topologyKey: String) -> Preparation {
        let state = availability()
        guard state == .available else {
            log?.write("[preset] action=overwrite result=skip detail=unavailable=\(state)")
            return .finished(.unavailable(state))
        }
        guard let preset = store.topology(key: topologyKey)?.presets.first(where: { $0.id == presetID }) else {
            return .finished(fail("预设不存在（可能已被删除）"))
        }
        guard confirm.confirmOverwrite(presetName: preset.name) else {
            log?.write("[preset] action=overwrite result=cancelled")
            return .finished(.cancelled)
        }
        return .confirmed
    }

    private func captureLayout() -> Result<LayoutCapture, Error> {
        Result { try capture() }
    }

    /// 校验拍快照的拓扑后写盘
    private func write(_ captured: Result<LayoutCapture, Error>, presetID: String,
                       topologyKey: String) -> OverwritePresetOutcome {
        let layout: LayoutCapture
        switch captured {
        case .success(let value): layout = value
        case .failure(SnapshotCaptureError.restoreInProgress):
            log?.write("[preset] action=overwrite result=skip detail=unavailable=restoring")
            return .unavailable(.restoring)
        case .failure(let error):
            return fail("拍快照失败：\(SavePresetFlow.describe(error))")
        }
        guard !layout.topology.isMirrored else {
            log?.write("[preset] action=overwrite result=skip detail=unavailable=mirrored")
            return .unavailable(.mirrored)
        }
        guard layout.topology.identity.key == topologyKey else {
            log?.write("[preset] action=overwrite topology=\(topologyKey) result=skip "
                + "detail=topology-mismatch current=\(layout.topology.identity.key)")
            _ = fail("屏幕排列已变化，只能覆盖当前屏幕排列下的预设")
            return .topologyChanged
        }
        do {
            let preset = try store.overwritePreset(id: presetID, snapshot: layout.snapshot, topology: layout.topology)
            return .overwritten(name: preset.name, topologyKey: topologyKey)
        } catch {
            return fail("写入预设失败：\(String(describing: error))")
        }
    }

    private func fail(_ reason: String) -> OverwritePresetOutcome {
        log?.write("[preset] action=overwrite result=fail detail=\(reason)")
        notifier?.deliver(title: "覆盖预设失败", body: reason)
        return .failed(reason)
    }
}

extension RuntimeAssembly {
    /// 组装覆盖流程：拍快照与保存流程同参数（同一 session 独占、同一延迟几何覆盖），可用性取保存流程同口径；
    /// 本应用自身窗口（管理窗口）不入快照——覆盖从管理窗口发起时它正开着。
    public static func makeOverwritePresetFlow(availability: @escaping () -> SavePresetAvailability,
                                               store: PresetStore,
                                               spaces: SpaceProviding?,
                                               session: SkyLightSession,
                                               deferredGeometry: DeferredGeometryPort? = nil,
                                               confirm: PresetOverwriteConfirming = AlertPresetOverwriteConfirm(),
                                               notifier: SystemNotifying? = nil,
                                               log: LogWriting? = nil) -> OverwritePresetFlow {
        let engine = SnapshotEngine(spaces: spaces, log: log, deferredGeometry: deferredGeometry, session: session)
        let ownBundleID = Bundle.main.bundleIdentifier
        return OverwritePresetFlow(store: store,
                                   capture: {
                                       let captured = try engine.capture()
                                       var snapshot = captured.snapshot
                                       snapshot.windows.removeAll { $0.bundleID == ownBundleID }
                                       return LayoutCapture(snapshot: snapshot, topology: captured.topology)
                                   },
                                   availability: availability,
                                   confirm: confirm,
                                   notifier: notifier,
                                   log: log)
    }
}

/// 生产确认框：NSAlert（菜单栏 agent 应用须先激活自身，否则确认框不在前台）
public final class AlertPresetOverwriteConfirm: PresetOverwriteConfirming {
    public init() {}

    public func confirmOverwrite(presetName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "用当前布局覆盖「\(presetName)」？"
        alert.informativeText = "预设原有的布局将被替换，名称与自动标记保留。此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "覆盖")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
