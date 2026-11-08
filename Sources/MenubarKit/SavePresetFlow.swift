import AppKit
import Core
import SnapshotEngine

// SavePresetFlow.swift — 「保存当前布局为预设…」（display-presets spec §4.3，票 03）。
// 流程：可用性门（未就绪 / 镜像中 / 恢复进行中 → 禁用）→ 一次性拍快照（SnapshotEngine.capture，点击时刻的布局，
// 先于输入框拍：输入期间的窗口变化与输入框自身不入快照）→ 输入框（默认名「MM-dd HH:mm」，可改）
// → 存入拍快照时的拓扑（PresetStore.addPreset；拓扑首个预设默认自动）。撞名/空名提示后重弹，取消不写。
// 菜单项接线（票 06）：可用性取 availability()（非 .available 置灰），点击调 runAsync()——拍快照（SLS/AX 读，
// 遇无响应应用的 AX 读可达数秒）经 captureExecutor 离开主线程，输入框（模态）与写盘经 mainExecutor 回到主线程。

/// 预设名输入框接缝（生产：AlertPresetNamePrompt；测试：脚本假件）
public protocol PresetNamePrompting: AnyObject {
    /// 弹输入框：defaultName 预填；message = 上次输入的问题提示（首次 nil）。返回 nil = 取消
    func promptPresetName(defaultName: String, message: String?) -> String?
}

/// 保存入口可用性（spec §4.3 禁用三态）
public enum SavePresetAvailability: Equatable {
    case available
    /// 两项授权未齐（未就绪门控）
    case notReady
    /// 任一屏处于镜像集合（spec §3.3）
    case mirrored
    /// 恢复/撤销管线进行中
    case restoring
}

/// 一次保存流程的结果
public enum SavePresetOutcome: Equatable {
    case saved(name: String, topologyKey: String)
    /// 用户在输入框取消
    case cancelled
    /// 禁用态（菜单项本应置灰；拍快照时才发现的镜像/恢复也归此）
    case unavailable(SavePresetAvailability)
    /// 拍快照或写盘失败（已通知用户）
    case failed(String)
}

public final class SavePresetFlow {
    private let store: PresetStore
    private let capture: () throws -> LayoutCapture
    private let prompt: PresetNamePrompting
    private let isReady: () -> Bool
    private let isMirrored: () -> Bool
    private let isRestoring: () -> Bool
    private let notifier: SystemNotifying?
    private let log: LogWriting?
    private let now: () -> Date
    private let nameFormatter: DateFormatter
    private let captureExecutor: (@escaping () -> Void) -> Void
    private let mainExecutor: (@escaping () -> Void) -> Void
    /// runAsync 一轮进行中（拍快照 → 输入框 → 写盘）；只在 mainExecutor 所在线程（主线程）读写
    private var isRunning = false

    /// - Parameters:
    ///   - capture: 一次性拍快照（生产 = SnapshotEngine.capture）
    ///   - isReady: 未就绪门（生产 = PermissionMonitor.status.isReady）
    ///   - isMirrored: 镜像检测（生产 = ObservedTopology.current().isMirrored）
    ///   - isRestoring: 恢复进行中（生产 = SkyLightSession.shouldYield：恢复/撤销管线持有或排队独占）
    ///   - notifier: 失败通知（nil = 只记日志）
    ///   - captureExecutor / mainExecutor: runAsync 的两段执行器（生产 = 全局队列 / 主队列；测试手动推进）
    public init(store: PresetStore,
                capture: @escaping () throws -> LayoutCapture,
                prompt: PresetNamePrompting,
                isReady: @escaping () -> Bool,
                isMirrored: @escaping () -> Bool,
                isRestoring: @escaping () -> Bool,
                notifier: SystemNotifying? = nil,
                log: LogWriting? = nil,
                now: @escaping () -> Date = Date.init,
                timeZone: TimeZone = .current,
                captureExecutor: @escaping (@escaping () -> Void) -> Void = { work in
                    DispatchQueue.global(qos: .userInitiated).async(execute: work)
                },
                mainExecutor: @escaping (@escaping () -> Void) -> Void = { work in
                    DispatchQueue.main.async(execute: work)
                }) {
        self.store = store
        self.capture = capture
        self.prompt = prompt
        self.isReady = isReady
        self.isMirrored = isMirrored
        self.isRestoring = isRestoring
        self.notifier = notifier
        self.log = log
        self.now = now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM-dd HH:mm"
        self.nameFormatter = formatter
        self.captureExecutor = captureExecutor
        self.mainExecutor = mainExecutor
    }

    /// 保存入口当前可用性（菜单构建时调用；判定顺序：未就绪 > 镜像中 > 恢复进行中）
    public func availability() -> SavePresetAvailability {
        if !isReady() { return .notReady }
        if isMirrored() { return .mirrored }
        if isRestoring() { return .restoring }
        return .available
    }

    /// 走一遍保存流程（同步：拍快照、输入框、写盘都在调用线程；菜单路径用 runAsync）
    @discardableResult
    public func run() -> SavePresetOutcome {
        if let refused = gate() { return refused }
        return promptAndSave(captureLayout())
    }

    /// 菜单路径（主线程调用）：门判定在调用线程；拍快照经 captureExecutor 离开主线程，
    /// 输入框与写盘经 mainExecutor 回到主线程，completion 在该线程回调。
    /// 上一轮未结束（拍快照中 / 输入框开着）时不受理，返回 false 且不回调。
    @discardableResult
    public func runAsync(completion: @escaping (SavePresetOutcome) -> Void) -> Bool {
        guard !isRunning else {
            log?.write("[preset] action=save result=skip detail=in-flight")
            return false
        }
        if let refused = gate() {
            completion(refused)
            return true
        }
        isRunning = true
        captureExecutor { [self] in
            let captured = captureLayout()
            mainExecutor { [self] in
                let outcome = promptAndSave(captured)
                isRunning = false
                completion(outcome)
            }
        }
        return true
    }

    /// 门：禁用态返回 .unavailable（菜单项本应置灰，防御）
    private func gate() -> SavePresetOutcome? {
        let state = availability()
        guard state == .available else {
            log?.write("[preset] action=save result=skip detail=unavailable=\(state)")
            return .unavailable(state)
        }
        return nil
    }

    /// 拍快照这一步的产物：拿到快照，或流程已有定论（门后才发现的恢复/镜像 → 不可用；其余失败已通知）
    private enum CaptureStep {
        case captured(LayoutCapture)
        case finished(SavePresetOutcome)
    }

    private func captureLayout() -> CaptureStep {
        let captured: LayoutCapture
        do {
            captured = try capture()
        } catch SnapshotCaptureError.restoreInProgress {
            log?.write("[preset] action=save result=skip detail=unavailable=restoring")
            return .finished(.unavailable(.restoring))
        } catch {
            return .finished(fail("拍快照失败：\(Self.describe(error))"))
        }
        guard !captured.topology.isMirrored else {
            log?.write("[preset] action=save result=skip detail=unavailable=mirrored")
            return .finished(.unavailable(.mirrored))
        }
        return .captured(captured)
    }

    /// 输入框 → 写盘（主线程：输入框模态）
    private func promptAndSave(_ step: CaptureStep) -> SavePresetOutcome {
        let captured: LayoutCapture
        switch step {
        case .captured(let value): captured = value
        case .finished(let outcome): return outcome
        }
        var defaultName = nameFormatter.string(from: now())
        var message: String?
        // 撞名/空名：提示后带着刚输入的名称重弹，直到存入或取消（spec §4.1 撞名提示改名）
        while let name = prompt.promptPresetName(defaultName: defaultName, message: message) {
            do {
                let preset = try store.addPreset(name: name, snapshot: captured.snapshot, topology: captured.topology)
                return .saved(name: preset.name, topologyKey: captured.topology.identity.key)
            } catch PresetStoreError.duplicateName(let existing) {
                message = "已有名为「\(existing)」的预设，请换一个名称"
            } catch PresetStoreError.emptyName {
                message = "名称不能为空"
            } catch PresetStoreError.mirrored {
                return .unavailable(.mirrored)
            } catch {
                return fail("写入预设失败：\(Self.describe(error))")
            }
            defaultName = name
        }
        log?.write("[preset] action=save result=cancelled")
        return .cancelled
    }

    private func fail(_ reason: String) -> SavePresetOutcome {
        log?.write("[preset] action=save result=fail detail=\(reason)")
        notifier?.deliver(title: "保存预设失败", body: reason)
        return .failed(reason)
    }

    private static func describe(_ error: Error) -> String {
        switch error as? SnapshotCaptureError {
        case .noActiveDisplay?: return "无活动显示器"
        case .topologyChangedWhileComposing?: return "拍快照期间屏幕排列发生变化，请稍后重试"
        case .restoreInProgress?: return "恢复进行中"
        case nil: return String(describing: error)
        }
    }
}

extension RuntimeAssembly {
    /// 组装保存预设流程（票 06 在 assembleAppRoot 内以同一 presetStore/adapter/session/deferredGeometry 调用）：
    /// 拍快照 = 一次性 SnapshotEngine（spaces 注入 Space 归属；deferredGeometry 提供待补写窗的几何覆盖），
    /// 未就绪门 = monitor，恢复进行中 = session 独占持有/排队，镜像 = 实况拓扑。
    public static func makeSavePresetFlow(gatedBy monitor: PermissionMonitor,
                                          store: PresetStore,
                                          spaces: SpaceProviding?,
                                          session: SkyLightSession,
                                          deferredGeometry: DeferredGeometryPort? = nil,
                                          prompt: PresetNamePrompting = AlertPresetNamePrompt(),
                                          notifier: SystemNotifying? = nil,
                                          log: LogWriting? = nil,
                                          isMirrored: @escaping () -> Bool = { ObservedTopology.current().isMirrored })
        -> SavePresetFlow {
        let engine = SnapshotEngine(spaces: spaces, log: log, deferredGeometry: deferredGeometry, session: session)
        return SavePresetFlow(store: store,
                              capture: { try engine.capture() },
                              prompt: prompt,
                              isReady: { [monitor] in monitor.status.isReady },
                              isMirrored: isMirrored,
                              isRestoring: { session.shouldYield },
                              notifier: notifier,
                              log: log)
    }
}

/// 生产输入框：NSAlert + 单行文本框（菜单栏 agent 应用须先激活自身，否则输入框不在前台）
public final class AlertPresetNamePrompt: PresetNamePrompting {
    public init() {}

    public func promptPresetName(defaultName: String, message: String?) -> String? {
        let alert = NSAlert()
        alert.messageText = "保存当前布局为预设"
        alert.informativeText = message ?? "预设将保存到当前屏幕排列下。"
        alert.alertStyle = message == nil ? .informational : .warning
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
