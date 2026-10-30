import AppKit
import Core
import Foundation

// SnapshotEngine.swift — 快照引擎（spec §7.5/§10.1，票 12）。
// 节奏：每 2s CGWindowListCopyWindowInfo(.optionAll) 差分（timer tolerance 0.5s）；
//       无变化不写盘；有变化防抖 1s 落盘（连续变化合并为一次写入）。
// 加速器：应用启退（NSWorkspace didLaunch/didTerminate）、屏幕事件（didChangeScreenParameters）
//       触发立即差分一次；Space 切换加速器由票 17/18 观察方调 pollNow() 接入（公开入口即差分入口）。
// 存储：经 Core/SnapshotStore —— 现势 1 份 + 滚动历史 4 份（最旧淘汰，文件名格式票 11 冻结）。
// 零 AX：轮询环只读 CG（见 WindowSampling.swift）；AX 仅写盘路径（见 MinimalAXReader.swift）。
// 门控：readinessGate 默认恒就绪；未就绪 = 照常轮询但零落盘（票 18 接真实两项授权检查）。

public enum SnapshotEngineConstants {
    /// 快照轮询周期（spec §10.3，04 #8）
    public static let pollInterval: TimeInterval = 2.0
    /// 轮询 timer tolerance（spec §7.5）
    public static let pollTolerance: TimeInterval = 0.5
    /// 落盘防抖（spec §10.3，04 #8）
    public static let writeDebounce: TimeInterval = 1.0
    /// 辅助窗排除边长（px，与 VerifyCLI/spike 同口径）
    static let minWindowEdge: Double = 40
}

public final class SnapshotEngine {
    /// 就绪门（票 18 接两项授权检查；默认恒就绪）。未就绪 = 照常轮询但零落盘。
    public var readinessGate: () -> Bool = { true }

    private let store: SnapshotStore
    private let composer: SnapshotComposer
    private let enumerator: WindowEnumerating
    private let displaysProvider: () -> [Displays.Info]
    private let log: LogWriting?
    private let pollInterval: TimeInterval
    private let pollTolerance: TimeInterval
    private let debounceInterval: TimeInterval
    private let lock = NSLock()
    private var lastFingerprint: WindowFingerprint?
    private var debounceItem: DispatchWorkItem?
    private let debounceQueue = DispatchQueue(label: "wlr.snapshot-engine.debounce")

    private var pollTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    public init(store: SnapshotStore,
                spaces: SpaceProviding?,
                log: LogWriting? = nil,
                enumerator: WindowEnumerating = CGWindowListEnumerator(),
                ax: WindowAXProbing = MinimalAXReader(),
                displaysProvider: @escaping () -> [Displays.Info] = Displays.active,
                pollInterval: TimeInterval = SnapshotEngineConstants.pollInterval,
                pollTolerance: TimeInterval = SnapshotEngineConstants.pollTolerance,
                debounceInterval: TimeInterval = SnapshotEngineConstants.writeDebounce) {
        self.store = store
        self.composer = SnapshotComposer(spaces: spaces, ax: ax)
        self.enumerator = enumerator
        self.displaysProvider = displaysProvider
        self.log = log
        self.pollInterval = pollInterval
        self.pollTolerance = pollTolerance
        self.debounceInterval = debounceInterval
    }

    deinit { stop() }

    // MARK: 生命周期

    /// 启动轮询 timer（2s ± 0.5s）与加速器观察（应用启退、屏幕事件）
    public func start() {
        pollNow()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "wlr.snapshot-engine.poll"))
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval,
                       leeway: .nanoseconds(Int(pollTolerance * 1_000_000_000)))
        timer.setEventHandler { [weak self] in self?.pollNow() }
        timer.resume()
        pollTimer = timer

        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSApplication.didChangeScreenParametersNotification,  // 屏幕事件（插拔/分辨率/旋转）
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.pollNow()  // 加速器：立即差分一次
            }
        }
    }

    public func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers = []
        lock.lock()
        debounceItem?.cancel()
        debounceItem = nil
        lock.unlock()
    }

    // MARK: 差分与落盘

    /// 差分一次（轮询 timer、加速器、调试命令共用入口；Space 切换观察方也接这里）。
    /// 返回是否检出变化。有变化且已就绪 → 排定防抖落盘（连续变化自动合并）。
    @discardableResult
    public func pollNow() -> Bool {
        let fingerprint = WindowFingerprint(displays: displaysProvider(), windows: enumerator.sample())
        lock.lock()
        if fingerprint == lastFingerprint {
            lock.unlock()
            return false  // 无变化不写盘
        }
        lastFingerprint = fingerprint
        lock.unlock()
        guard readinessGate() else {
            log?.write("[snapshot] action=poll result=skip detail=not-ready 检出变化但未就绪，零落盘（票 18 接线）")
            return true
        }
        scheduleDebouncedWrite()
        return true
    }

    /// 立即执行挂起的防抖落盘（防抖期内变化合并 ⇒ 一次写入）。测试与 snapshot-now 驱动用。
    public func writePendingNow() {
        lock.lock()
        debounceItem?.cancel()
        debounceItem = nil
        lock.unlock()
        performWrite()
    }

    private func scheduleDebouncedWrite() {
        lock.lock()
        debounceItem?.cancel()  // 防抖：新变化重置 1s 等待，连续变化合并为一次写入
        let item = DispatchWorkItem { [weak self] in self?.performWrite() }
        debounceItem = item
        lock.unlock()
        debounceQueue.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    private func performWrite() {
        guard readinessGate() else { return }  // 未就绪零落盘
        let displays = displaysProvider()
        guard !displays.isEmpty else {
            log?.write("[snapshot] action=write path=- result=fail detail=no-active-display")
            return
        }
        let snapshot = composer.compose(sample: enumerator.sample(), displays: displays, capturedAt: Date())
        let key = SnapshotStore.topologyKey(forDisplayUUIDs: displays.compactMap(\.uuid).filter { !$0.isEmpty })
        do {
            try store.write(snapshot, topologyKey: key)  // 现势 1 + 滚动历史 4（SnapshotStore 内滚动）
        } catch {
            log?.write("[snapshot] action=write path=live-\(key).json result=fail detail=\(error)")
        }
    }
}
