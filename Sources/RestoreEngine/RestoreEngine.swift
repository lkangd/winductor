import AXFacade
import Core
import CoreGraphics
import Foundation
import SnapshotEngine
import SpaceAdapter

// RestoreEngine.swift — 恢复引擎核心（票 14 L1+L2；票 15 L3 全屏最后 + L4 最小化恢复，spec §6.4/§6.5/§6.7/§6.8/§7.1/§7.4）。
// 一次性恢复（spec §6.3）：单轮写完即停，无重试循环；逐窗口逐层结构化日志（spec §10.4）+ 结束计数。
// 管线（§6.8 顺序铁律）：保守匹配 → 回滚快照（动手前）→ 逐窗口桥接 Space 移动（L2，屏+Space 一步到位）
//   → AX 几何摆位（L1，比例坐标 × 所属屏 CGDisplayBounds，旋转变化按轴向互换 best-effort）
//   → 全屏最后（L3：目标屏就位 → AXFullScreen=true → 等动画 §10.3）→ 最小化窗口恢复（L4，§6.5）。
// 全屏应用不进 windows 条目（schema §7.3），由快照 fullscreen Space 携带 bundleID 表示；全屏窗几何不触碰。
// 降级阶梯（§6.1）：L3/L4 各自经 SpaceLayer 探针逐层判定，某层不可用只降该层，其余照常。
// 保守匹配（spec §6.4）：Core.ConservativeMatcher（verify 共用同一份，08 #1）；
//   未运行应用不启动、快照外窗口/应用不动、粘性窗与无归属辅助窗不入恢复集合（spec §5.3）。

/// 引擎无法启动的错误（逐窗口问题不 throw，走 best-effort 日志 + 计数，spec §6.3）
/// 单窗 AX 写限时执行的跨线程结果盒（泛型函数内不可嵌套类，同 SpaceAdapter.BoundedResultBox 口径）
private final class PlaceBox: @unchecked Sendable {
    // 工作线程写、调用方轮询读：须加锁（Result<Void, Error> 多字长，无锁读可撕裂）
    private let lock = NSLock()
    private var _value: Result<Void, Error>?
    var value: Result<Void, Error>? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

public enum RestoreEngineError: Error, Equatable, Sendable {
    case noActiveDisplay
    /// 回滚快照写失败：无撤销保险不动手，整个恢复中止（spec §7.4「恢复中途崩溃撤销必须在」）
    case undoSnapshotWriteFailed(String)
    /// 撤销入口禁用：回滚快照不存在（spec §7.4「仅文件存在时可用」，票 16）
    case undoSnapshotMissing
    /// 撤销入口禁用：回滚快照损坏/版本拒用（解析失败已按 §7.4 隔离挪开，下次恢复重写；票 16）
    case undoSnapshotCorrupt(String)
    /// AX 几何写单窗限时超时（转延迟几何，消费轮询在 app 不忙后补写）
    case axApplyTimeout
    /// 所属 app 的 AX 窗口表已读到但不含该窗（非 AX 窗口：浏览器气泡/信息栏等辅助条），写必失败
    case notAXWindow
}

/// 一次性恢复的结果（spec §6.3：结束产出成功/跳过/失败计数；票 15/16 增量扩展）
public struct RestoreReport: Equatable, Sendable {
    /// 处理条目级：无任何动作失败（常规窗 + 全屏 Space + 最小化窗；降级跳过不计失败，spec §6.1 逐层降级）
    public let okCount: Int
    /// 处理条目级：未匹配（含未运行）/ 目标屏缺失 / 降级层跳过（L3/L4 失效原地不动，spec §6.1/§6.5）
    public let skipCount: Int
    /// 处理条目级：任一动作 fail（桥接 no-op、AX 写失败等）
    public let failCount: Int
    /// 配对条目数（一级 + 二级几何兜底）
    public let matchedCount: Int
    /// 快照外不动窗口数（spec §6.4b）
    public let untouchedLiveCount: Int
    /// 回滚快照落点
    public let undoSnapshotURL: URL?
    /// 本轮被协作式取消（触发链：恢复中拓扑变化）：已动的窗口不回滚，剩余条目计 skip
    public var cancelled: Bool = false
}

/// 恢复协作式取消令牌（display-presets spec §5.1「恢复进行中拓扑变了：立即中止本轮」）。
/// 触发链持有并在拓扑变化时 cancel()；引擎在逐窗口/逐层之间检查，已移动的窗口不回滚，
/// 回滚快照照常保留（可撤销）。线程安全：事件线程写、管线线程读。
public final class RestoreCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    public init() {}

    public func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }
}

/// 撤销结果（票 16，spec §6.3/§8.6）：计数口径与 RestoreReport 一致，另带两段式撤销的全屏待办数。
public struct UndoReport: Equatable, Sendable {
    /// 处理条目级：无任何动作失败（常规窗 + 全屏 Space + 最小化窗；降级跳过不计失败）
    public let okCount: Int
    /// 处理条目级：未匹配（含未运行）/ 目标屏缺失 / 降级层跳过 / 两段式第一段全屏待办
    public let skipCount: Int
    /// 处理条目级：任一动作 fail（桥接 no-op、AX 写失败等）
    public let failCount: Int
    /// 配对条目数（一级 + 二级几何兜底）
    public let matchedCount: Int
    /// 快照外不动窗口数（spec §6.4b）
    public let untouchedLiveCount: Int
    /// 回滚快照落点（撤销后保留，spec §7.4：重复撤销幂等无害，至下次恢复才被覆盖）
    public let undoSnapshotURL: URL
    /// 两段式第一段待办数（§8.6 文案中的 N）：卡在后台全屏、需用户按 Esc 后二次撤销补完的全屏条目数
    public let fullscreenPendingCount: Int
    /// 两段式第一段 = 存在全屏待办（票 19 据此投递 §8.6 文案）
    public var isTwoStageFirstPass: Bool { fullscreenPendingCount > 0 }

    /// 09 八通知文案（spec §8.6 逐字）：仅两段式第一段非 nil；系统通知投递归票 19，DebugCLI 直接打印
    public var twoStageNotificationText: String? {
        guard fullscreenPendingCount > 0 else { return nil }
        return "撤销完成。\(fullscreenPendingCount) 个全屏应用无法在后台退出全屏："
            + "请在对应屏幕按 Esc 退出全屏，然后再次点击「撤销上次恢复」完成剩余归位。"
    }
}

/// 恢复视角的实况窗口（单 Space 归属；粘性窗/无归属辅助窗不入列 = 保守「不动」，spec §5.3）
public struct LiveRestoreWindow: Equatable, Sendable {
    public let cgWindowID: UInt32
    public let bundleID: String
    public let title: String
    /// 当前所属屏稳定 UUID（屏归属：Space 所属屏优先，Core.LiveWindowLocator）
    public let displayUUID: String
    /// 当前 Space id64（SLSCopySpacesForWindows 单归属）
    public let spaceID: Int64
    /// 所属屏归一比例坐标（spec §7.2）
    public let x: Double, y: Double, w: Double, h: Double
    public let minimized: Bool
    /// 是否在可见 Space（后台窗 AX 不可见，几何写会 elementInvalid → 走延迟几何）
    public let isOnscreen: Bool
}

public final class RestoreEngine: @unchecked Sendable {
    /// 回滚快照所在（每拓扑一份，PresetStore.undoURL）
    private let store: PresetStore
    private let spaces: SpaceBridge
    private let enumerator: WindowEnumerating
    private let ax: WindowAXProbing
    /// 管线死线（秒）：超时剩余条目计 skip、通知照发——无论系统级楔死拖慢哪层，通知计数必须有界到达
    private let pipelineDeadlineSeconds: TimeInterval
    /// L1 单窗 AX 写限时（秒）：插屏后各 app AX 响应变慢（实测 4.6s/项），限时转延迟几何保通知秒级
    private static let axApplyTimeoutSeconds: TimeInterval = 1.5
    private let geometry: WindowGeometryWriting
    /// 管线全程独占 SkyLight（与 poller 写盘 / pending 补写互斥；多条管线串行）
    private let session: SkyLightSession
    /// 后台窗延迟几何（AX 树不含非可见 Space 窗 → elementInvalid 的补救路径）
    private let deferredGeometry: DeferredGeometry
    /// 本轮 pending（runPipeline 开始清零，结束整写替换 pending 文件）
    private var runPendingGeometry: [PendingGeometryEntry] = []
    /// L1 并发 lanes 共享状态锁（runPendingGeometry / outcomes）：无锁并发 append 实测堆损坏崩溃，
    /// 生产上可静默丢 pending 条目（被延迟的窗再无补写）
    private let l1Lock = NSLock()
    /// L3 全屏写（AXFullScreen；票 15）
    private let fullscreen: WindowFullScreenWriting
    /// L4 最小化写（AXMinimized；票 15）
    private let minimize: WindowMinimizeWriting
    /// 全屏动画等待（§10.3 全屏动画等待 0.5–1s，取上限；测试注入 0 跳过）
    private let fullscreenSettleSeconds: TimeInterval
    /// 最后一次实际桥接移窗 → L1 几何写的最小间隔（秒）。桥接结算改为轮询归属后不再固定等 1.2s，
    /// 归属先于窗口帧落定，留一小段让 WindowServer 完成移屏，防 L1 写被随后的移屏覆盖
    private let postBridgeSettleSeconds: TimeInterval
    /// 本轮最后一次实际桥接移窗的时刻（L2 串行，只在管线线程读写）
    private var lastBridgeMoveAt: Date?
    private let displaysProvider: () -> [Displays.Info]
    private let rotationProvider: (CGDirectDisplayID) -> Int
    private let log: LogWriting?
    /// 回滚快照组装复用票 12 的 SnapshotComposer（同一 schema 口径，spec §7.3）
    private let composer: SnapshotComposer

    public init(store: PresetStore,
                spaces: SpaceBridge,
                enumerator: WindowEnumerating = CGWindowListEnumerator(),
                ax: WindowAXProbing = MinimalAXReader(),
                geometry: WindowGeometryWriting = AXGeometryWriter(),
                session: SkyLightSession = SkyLightSession(),
                fullscreen: WindowFullScreenWriting = AXFullScreenWriter(),
                minimize: WindowMinimizeWriting = AXMinimizeWriter(),
                fullscreenSettleSeconds: TimeInterval = 1.0,
                postBridgeSettleSeconds: TimeInterval = 0.3,
                pipelineDeadlineSeconds: TimeInterval = 90,
                deferredGeometry: DeferredGeometry? = nil,
                displaysProvider: @escaping () -> [Displays.Info] = Displays.active,
                rotationProvider: @escaping (CGDirectDisplayID) -> Int = Displays.rotation,
                log: LogWriting? = nil) {
        self.store = store
        self.spaces = spaces
        self.enumerator = enumerator
        self.ax = ax
        self.geometry = geometry
        self.session = session
        self.fullscreen = fullscreen
        self.minimize = minimize
        self.fullscreenSettleSeconds = fullscreenSettleSeconds
        self.postBridgeSettleSeconds = postBridgeSettleSeconds
        self.pipelineDeadlineSeconds = pipelineDeadlineSeconds
        // 缺省（DebugCLI / 单测）：同目录落 pending 文件，由运行中 app 的延迟几何模块消费
        self.deferredGeometry = deferredGeometry
            ?? DeferredGeometry(directory: store.directory, spaces: spaces, session: session, log: log)
        self.displaysProvider = displaysProvider
        self.rotationProvider = rotationProvider
        self.log = log
        self.composer = SnapshotComposer(spaces: spaces, ax: ax)
    }

    /// 一次性恢复入口。抛错仅限「无法启动」（无显示器 / 回滚快照写失败）；
    /// 逐窗口问题一律记日志计数，不中断（spec §6.3 单轮 best-effort）。
    @discardableResult
    public func restore(snapshot: Snapshot) throws -> RestoreReport {
        try restore(snapshot: snapshot, preserveUndo: false)
    }

    /// preserveUndo = true：沿用既有回滚快照不重写（触发链余震重放：此刻实况是被 macOS 余震
    /// 打乱的恢复结果，重写会让「撤销」回到乱序态而非首轮恢复前）
    @discardableResult
    public func restore(snapshot: Snapshot, preserveUndo: Bool) throws -> RestoreReport {
        try restore(snapshot: snapshot, preserveUndo: preserveUndo, cancellation: nil)
    }

    /// cancellation = 协作式取消令牌（触发链传入；nil = 不可取消）。取消后剩余条目计 skip，
    /// 报告 cancelled = true；回滚快照已在动手前写好，照常可撤销
    @discardableResult
    public func restore(snapshot: Snapshot, preserveUndo: Bool,
                        cancellation: RestoreCancellation?) throws -> RestoreReport {
        // 拓扑在独占内读取：排队等前一条管线期间可能插拔屏
        let counts = try session.exclusive("restore") { () throws -> PipelineCounts in
            let displays = try activeDisplays(label: "restore")
            return try runPipelineExclusive(snapshot: snapshot, mode: .restore, displays: displays,
                                            preserveUndo: preserveUndo, cancellation: cancellation)
        }
        return RestoreReport(
            okCount: counts.okCount, skipCount: counts.skipCount, failCount: counts.failCount,
            matchedCount: counts.matchedCount, untouchedLiveCount: counts.untouchedLiveCount,
            undoSnapshotURL: counts.undoSnapshotURL, cancelled: counts.cancelled)
    }

    /// 撤销入口（票 16，spec §6.3/§8.6）：读回滚快照整体回滚——把恢复前实况当作恢复目标跑一次恢复语义
    /// （几何/Space/屏幕一步回滚；全屏/最小化条目按回滚快照语义处理）。
    /// 含全屏应用走两段式：第一段跳过卡在后台全屏的应用并计 fullscreenPendingCount（§8.6 文案 N），
    /// 用户按 Esc（全屏 Space 自动销毁、窗口归原 Space）后再次撤销补完几何回滚；
    /// 回滚快照撤销后保留（§7.4），重复撤销幂等无害。
    /// 抛错 = 入口禁用（回滚快照缺失/损坏，spec §7.4）或无显示器。
    public func undo() throws -> UndoReport {
        // 回滚快照在独占内读取：排在恢复之后的撤销须读到该恢复刚写的回滚快照，而非上一轮的
        let (counts, undoURL) = try session.exclusive("undo") { () throws -> (PipelineCounts, URL) in
            let displays = try activeDisplays(label: "undo")
            let loaded = try readUndoSnapshot(displays: displays, quarantineOnCorrupt: true)
            return (try runPipelineExclusive(snapshot: loaded.snapshot, mode: .undo, displays: displays,
                                             preserveUndo: false), loaded.url)
        }
        return UndoReport(
            okCount: counts.okCount, skipCount: counts.skipCount, failCount: counts.failCount,
            matchedCount: counts.matchedCount, untouchedLiveCount: counts.untouchedLiveCount,
            undoSnapshotURL: undoURL,
            fullscreenPendingCount: counts.fullscreenPendingCount)
    }

    private func activeDisplays(label: String) throws -> [Displays.Info] {
        let displays = displaysProvider()
        guard !displays.isEmpty else {
            log?.write("[\(label)] abort reason=no-active-display")
            throw RestoreEngineError.noActiveDisplay
        }
        return displays
    }

    /// 菜单「撤销上次恢复」可用性（spec §7.4/§8.2；票 19 接线）：回滚快照存在且可解析才可用
    /// （损坏 = 入口禁用，票面「缺失/损坏时入口禁用不崩溃」；菜单点击仍会拿到明确错误，不崩溃）
    public func canUndo() -> Bool {
        let displays = displaysProvider()
        guard !displays.isEmpty else { return false }
        return (try? readUndoSnapshot(displays: displays, quarantineOnCorrupt: false)) != nil
    }

    /// 读回滚快照（票 16，spec §7.4）：缺失抛 undoSnapshotMissing；
    /// 版本拒用/解析失败抛 undoSnapshotCorrupt（quarantineOnCorrupt = 仅解析失败先按 §7.4 隔离挪开，
    /// 下次恢复重写；可用性检查传 false 保持无副作用）
    private func readUndoSnapshot(displays: [Displays.Info],
                                  quarantineOnCorrupt: Bool) throws -> (snapshot: Snapshot, url: URL) {
        let undoURL = store.undoURL(topologyKey: topologyKey(of: displays))
        guard FileManager.default.fileExists(atPath: undoURL.path) else {
            log?.write("[undo] abort reason=undo-snapshot-missing path=\(undoURL.topologyRelativePath)")
            throw RestoreEngineError.undoSnapshotMissing
        }
        do {
            return (try Snapshot.decode(from: try Data(contentsOf: undoURL)), undoURL)
        } catch let error as SnapshotSchemaError {
            // 版本拒用不隔离（§7.3 口径，文件本身合法 JSON）：入口禁用
            log?.write("[undo] abort reason=undo-snapshot-rejected path=\(undoURL.topologyRelativePath) detail=\(error)")
            throw RestoreEngineError.undoSnapshotCorrupt(String(describing: error))
        } catch {
            // 解析失败 = 损坏：按 §7.4 改名 .corrupt-<时间戳> 隔离挪开（下次恢复重写），入口禁用
            let moved = quarantineOnCorrupt ? store.quarantine(undoURL) : nil
            log?.write("[undo] abort reason=undo-snapshot-corrupt path=\(undoURL.topologyRelativePath) "
                + "detail=\(error) quarantine=\(moved?.lastPathComponent ?? "failed")")
            throw RestoreEngineError.undoSnapshotCorrupt(String(describing: error))
        }
    }

    /// 当前拓扑键（TopologyIdentity：UUID 集合 + 邻接排列 + 旋转，display-presets spec §3.1）
    private func topologyKey(of displays: [Displays.Info]) -> String {
        Displays.topologyIdentity(of: displays, rotation: rotationProvider).key
    }

    // MARK: - 恢复 / 撤销共用管线（§6.8 顺序铁律）

    /// restore = 正常恢复（动手前重写回滚快照）；undo = 回滚（复用仍保留的回滚快照，不重写，票 16 §7.4）
    private enum RunMode {
        case restore
        case undo
    }

    /// 管线计数（RestoreReport / UndoReport 共用；fullscreenPendingCount 仅撤销模式非 0）
    private struct PipelineCounts {
        let okCount: Int
        let skipCount: Int
        let failCount: Int
        let matchedCount: Int
        let untouchedLiveCount: Int
        let fullscreenPendingCount: Int
        let undoSnapshotURL: URL
        let cancelled: Bool
    }

    /// 调用方须持有 session.exclusive（拓扑与回滚快照也须在独占内读取）
    private func runPipelineExclusive(snapshot: Snapshot, mode: RunMode,
                                      displays: [Displays.Info], preserveUndo: Bool,
                                      cancellation: RestoreCancellation? = nil) throws -> PipelineCounts {
        let undoURL = store.undoURL(topologyKey: topologyKey(of: displays))
        // 分段计时（恢复提速：每轮一行 perf，定位瓶颈段）
        let tStart = Date()

        switch mode {
        case .restore where preserveUndo && FileManager.default.fileExists(atPath: undoURL.path):
            log?.write("[snapshot] action=write path=\(undoURL.topologyRelativePath) result=skip detail=preserve-undo")
        case .restore:
            // §7.4：动手前先落回滚快照（当前实况按 schema 写 <拓扑键>/undo.json）；失败即中止
            do {
                let undo = composer.compose(sample: enumerator.sample(), displays: displays, capturedAt: Date())
                try SnapshotStore.atomicWrite(try undo.encoded(), to: undoURL)
                log?.write("[snapshot] action=write path=\(undoURL.topologyRelativePath) result=ok "
                    + "detail=windows=\(undo.windows.count)")
            } catch {
                log?.write("[snapshot] action=write path=\(undoURL.topologyRelativePath) result=fail detail=\(error)")
                throw RestoreEngineError.undoSnapshotWriteFailed(String(describing: error))
            }
        case .undo:
            // 票 16 §7.4：撤销复用仍保留的回滚快照、不重写（重复撤销幂等无害，至下次恢复才被覆盖）
            log?.write("[undo] action=load path=\(undoURL.topologyRelativePath) result=ok "
                + "detail=windows=\(snapshot.windows.count)")
        }

        // 桥接 no-op 失效标记作用域 = 本轮（display-presets 票 12）：上一轮的 no-op 不再连累本轮 L2
        spaces.beginRestoreRound()

        // Space 清单读取失败曾用 try? 静默吞掉 → entries 空 → 整轮 L2 skip（11-03 实测）：
        // 现显式记录并重试一次（同轮单次重试，非循环）；生产失败源 = poller 并发 SLS 冲突
        var entries = (try? spaces.managedSpaces()) ?? []
        if entries.isEmpty {
            log?.write("[restore] action=space-list result=retry detail=first-read-empty-or-failed")
            Thread.sleep(forTimeInterval: 0.3)
            entries = (try? spaces.managedSpaces()) ?? []
            if entries.isEmpty {
                log?.write("[restore] action=space-list result=failed detail=L2-will-skip-L1-proceeds")
            }
        }

        // 保守匹配（Core 共用代码，spec §7.1）+ 逐条目行动计划
        let live = collectLiveWindows(samples: enumerator.sample(), displays: displays, entries: entries)
        let outcome = ConservativeMatcher.match(
            snapshotWindows: snapshot.windows,
            liveWindows: live.map { LiveWindow(cgWindowID: $0.cgWindowID, bundleID: $0.bundleID,
                                               title: $0.title, x: $0.x, y: $0.y, w: $0.w, h: $0.h,
                                               minimized: $0.minimized) })

        // 实况窗卡在全屏 Space（kind=4，spec §5.1）：后台退出全屏不可达、桥接/几何写对它无效
        // （桥接 no-op 还会标记 L2 失效连累本轮其余项），快照普通窗条目一律先摘出不动：
        // 恢复模式计 skip（display-presets 票 12，验收4 实测）；撤销模式计两段式 pending（票 16 §8.6/§5.2）
        let entryBySpaceID = Dictionary(entries.map { ($0.spaceID, $0) }, uniquingKeysWith: { a, _ in a })
        let liveFullscreenWIDs = Set(live.filter { entryBySpaceID[$0.spaceID]?.kind == SpaceKind.fullscreen }
            .map(\.cgWindowID))

        let plan = planEntries(snapshot: snapshot, live: live, outcome: outcome,
                               entries: entries, displays: displays,
                               mode: mode, liveFullscreenWIDs: liveFullscreenWIDs)

        // Pass L2（§6.8 先桥接移窗：屏 + Space 一步到位）→ Pass L1（AX 几何摆位）
        // → Pass L3（全屏最后）→ Pass L4（最小化恢复）—— §6.8 顺序铁律
        let bridgeOK = spaces.isBridgeAvailable() && !entries.isEmpty
        // 可见窗优先：用户看得见的窗先恢复；后台窗（AX 不可见，几何走延迟应用）排尾部，
        // 楔死/死线发生时牺牲的是不可见项
        let actItems = plan.filter(\.canAct)
            .sorted { !$0.liveIsOnscreen && $1.liveIsOnscreen }
        var failed = Set<Int>()
        // 管线死线：无论哪层被系统级楔死拖慢，通知计数必须有界到达（用户实测通知迟到数分钟）
        let deadline = Date().addingTimeInterval(pipelineDeadlineSeconds)
        runPendingGeometry = []
        // deadlineHit = 本轮停手（死线 或 协作式取消）：剩余项一律计 skip，后续层不再动手
        var deadlineHit = false
        var cancelled = false
        func deadlineExceeded(_ processed: Int, _ total: Int) -> Bool {
            if deadlineHit { return true }
            if cancellation?.isCancelled == true {
                deadlineHit = true
                cancelled = true
                log?.write("[restore] action=cancelled detail=remaining=\(total - processed) items-marked-skip")
                return true
            }
            if Date() < deadline { return false }
            deadlineHit = true
            log?.write("[restore] action=deadline detail=waited=\(Int(pipelineDeadlineSeconds))s remaining=\(total - processed) items-marked-skip")
            return true
        }
        /// 层间取消点（只查取消，不查死线：死线语义沿用「L2 内触发即后续层不动手」）
        func stopBeforeLayer(_ processed: Int, _ total: Int) -> Bool {
            deadlineHit || (cancellation?.isCancelled == true && deadlineExceeded(processed, total))
        }
        var actProcessed = 0
        lastBridgeMoveAt = nil
        let tL2 = Date()
        for (offset, item) in actItems.enumerated() {
            if deadlineExceeded(offset, actItems.count) { break }
            // 逐项重查桥接可用性：桥接操作超时降级（runtime no-op）后，剩余项快速跳过，
            // 防 WindowServer 侧棋死把后续 SLS 查询一并拖住（实测 111s）；L1 几何照常
            bridgeMove(item, bridgeOK: bridgeOK && spaces.isBridgeAvailable(), failed: &failed)
            actProcessed += 1
        }
        if let moved = lastBridgeMoveAt {
            let remaining = postBridgeSettleSeconds - Date().timeIntervalSince(moved)
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        }
        let tPrepare = Date()
        // 一次遍历建 windowID → AX 元素索引（实测逐窗全量遍历 44 窗 105s，索引后秒级）
        geometry.prepare(windowIDs: actItems.compactMap { item in
            guard case .act(let lw, _, _, _, _) = item.action else { return nil }
            return lw.cgWindowID
        })
        // 后台窗精准判定数据源：各屏活跃 Space（一次 SLS 读；窗不在任一活跃 Space = AX 不可见）
        let activeSpaceIDs = (try? spaces.activeSpaceIDs()) ?? []
        // L1 并发执行（不同窗口不同 app 的 AX 写天然可并发；插屏后各 app AX 响应变慢，
        // 串行 4.6s/项 × N 项把通知拖到分钟级，实测 6 项 = 28s）：8 lanes + 单项 1.5s 限时
        // → 全程上限 ≈ ceil(N/8)×1.5s；超时项转延迟几何（消费轮询补写），通知秒级到达
        var deferredCount = 0
        let tL1 = Date()
        if !stopBeforeLayer(actProcessed, actItems.count) {
            var outcomes = [PlaceOutcome?](repeating: nil, count: actItems.count)
            DispatchQueue.concurrentPerform(iterations: actItems.count) { i in
                // 协作式取消点（逐窗）：取消后未开写的窗计 skip
                let outcome = cancellation?.isCancelled == true
                    ? .skipped : place(actItems[i], activeSpaceIDs: activeSpaceIDs)
                l1Lock.lock(); outcomes[i] = outcome; l1Lock.unlock()
            }
            for (i, outcome) in outcomes.enumerated() {
                switch outcome ?? .fail {
                case .ok: break
                case .deferred:
                    deferredCount += 1  // pending 已在 place 内记录（锁内追加）
                case .skipped:
                    deferredCount += 1  // 同计 skip（未尝试 ≠ 失败）
                case .fail:
                    failed.insert(actItems[i].snapshotIndex)
                }
                actProcessed += 1
            }
        } else {
            log?.write("[restore] action=l1-skipped detail=deadline-already-hit count=\(actItems.count)")
        }

        let tL3 = Date()
        // Pass L3（票 15）：快照 fullscreen Space（kind=fullscreen 携带 bundleID，不进 windows，§7.3）
        var ok3 = 0, skip3 = 0, fail3 = 0, pending3 = 0
        if !stopBeforeLayer(actProcessed, actItems.count) {
            restoreFullscreenSpaces(snapshot: snapshot, live: live, entries: entries, displays: displays,
            layerOK: spaces.isLayerAvailable(.fullscreen), bridgeOK: spaces.isBridgeAvailable(),
                                    mode: mode, ok: &ok3, skipped: &skip3, failed: &fail3, pending: &pending3)
        }

        // Pass L4（票 15，§6.8 顺序铁律最后一环）：最小化窗口送回快照 Space 并保持最小化
        let l4Items = plan.filter(\.isMinimizedRestore)
        let minimizedLayerOK = spaces.isLayerAvailable(.minimized)
        var ok4 = 0, skip4 = 0, fail4 = 0
        if !stopBeforeLayer(actProcessed, actItems.count) {
            for item in l4Items {
                restoreMinimizedWindow(item, layerOK: minimizedLayerOK,
                                       ok: &ok4, skipped: &skip4, failed: &fail4)
            }
        }

        // 死线未处理项计入跳过（未尝试 ≠ 失败；一次性结算防跨层重复计数）
        let deadlineSkipped = deadlineHit ? (actItems.count - actProcessed + l4Items.count
                                            + plan.filter(\.isPendingFullscreen).count) : 0
        let skipped = plan.count - actItems.count - l4Items.count + deadlineSkipped + deferredCount
        let pending = plan.filter(\.isPendingFullscreen).count + pending3
        let tEnd = Date()
        func ms(_ a: Date, _ b: Date) -> Int { Int((b.timeIntervalSince(a) * 1000).rounded()) }
        log?.write("[\(mode == .restore ? "restore" : "undo")] perf prep=\(ms(tStart, tL2)) l2=\(ms(tL2, tPrepare)) "
            + "ax-index=\(ms(tPrepare, tL1)) l1=\(ms(tL1, tL3)) l3l4=\(ms(tL3, tEnd)) total=\(ms(tStart, tEnd))")
        switch mode {
        case .restore:
            log?.write("[restore] done ok=\(actItems.count - failed.count + ok3 + ok4) "
                + "skip=\(skipped + skip3 + skip4) fail=\(failed.count + fail3 + fail4) "
                + "matched=\(outcome.matches.count) untouched=\(outcome.unmatchedLiveIndexes.count)")
        case .undo:
            log?.write("[undo] done ok=\(actItems.count - failed.count + ok3 + ok4) "
                + "skip=\(skipped + skip3 + skip4) fail=\(failed.count + fail3 + fail4) "
                + "pending=\(pending) matched=\(outcome.matches.count) untouched=\(outcome.unmatchedLiveIndexes.count)")
        }
        deferredGeometry.replacePending(runPendingGeometry)
        if !runPendingGeometry.isEmpty {
            log?.write("[restore] action=deferred-pending result=ok detail=\(runPendingGeometry.count) entries")
        }
        return PipelineCounts(
            okCount: actItems.count - failed.count + ok3 + ok4,
            skipCount: skipped + skip3 + skip4,
            failCount: failed.count + fail3 + fail4,
            matchedCount: outcome.matches.count,
            untouchedLiveCount: outcome.unmatchedLiveIndexes.count,
            fullscreenPendingCount: pending,
            undoSnapshotURL: undoURL,
            cancelled: cancelled)
    }

    // MARK: - 行动计划（匹配结果 → 每条目动作/跳过判定；skip 行只记一次）

    struct PlanItem {
        enum Action {
            /// 未配对（reason = app-not-running | unmatched，spec §6.4a/c）
            case unmatched(reason: String)
            /// 配对但不动（reason = target-display-absent）
            case skip(reason: String)
            /// 执行 L2+L1。targetSpace = nil 表示目标屏在拓扑内但无既有 Space 可落（仅降 L2，L1 照常）
            case act(live: LiveRestoreWindow, targetSpace: SpaceEntry?, mergedFrom: Int?,
                     targetDisplay: Displays.Info, capturedOrientation: Int)
            /// L4 最小化恢复（票 15，spec §6.5）：送回快照 Space 并保持最小化，几何不触碰
            case restoreMinimized(live: LiveRestoreWindow, targetSpace: SpaceEntry?, mergedFrom: Int?)
            /// 撤销两段式第一段：实况窗卡在后台全屏 Space，待用户 Esc 后第二段补完（票 16，spec §8.6）
            case pendingFullscreen(live: LiveRestoreWindow)
        }
        let snapshotIndex: Int
        /// 实况窗是否在可见 Space（可见窗优先恢复：用户看得见 + AX 可写几何）
        var liveIsOnscreen: Bool {
            switch action {
            case .act(let live, _, _, _, _), .restoreMinimized(let live, _, _),
                 .pendingFullscreen(let live):
                return live.isOnscreen
            case .unmatched, .skip:
                return true
            }
        }
        let snapshotWindow: SnapshotWindow
        let action: Action

        var canAct: Bool {
            if case .act = action { return true }
            return false
        }

        var isMinimizedRestore: Bool {
            if case .restoreMinimized = action { return true }
            return false
        }

        var isPendingFullscreen: Bool {
            if case .pendingFullscreen = action { return true }
            return false
        }
    }

    private func planEntries(snapshot: Snapshot, live: [LiveRestoreWindow],
                             outcome: MatchOutcome, entries: [SpaceEntry],
                             displays: [Displays.Info], mode: RunMode,
                             liveFullscreenWIDs: Set<UInt32>) -> [PlanItem] {
        let matchBySnapshot = Dictionary(uniqueKeysWithValues: outcome.matches.map { ($0.snapshotIndex, $0) })
        let liveBundleIDs = Set(live.map(\.bundleID))
        let capturedOrientation = Dictionary(uniqueKeysWithValues:
            snapshot.topology.map { ($0.uuid, $0.orientation) })
        var plan: [PlanItem] = []
        // 规划期整窗 skip（unmatched/app-not-running/target-display-absent）：按首个动作层 L2 记统一
        // skip 行（§10.4 冻结字段 + 文件头登记的 reason 扩展键；target = 快照意愿；
        // 未配对实况窗 wid=0/before=-，有实况窗则记其 Space 归属）
        func skipItem(_ s: Int, _ snap: SnapshotWindow, _ reason: String,
                      wid: UInt32?, liveSpaceID: Int64?) -> PlanItem {
            log?.write(StructuredLog.restoreLine(
                layer: SpaceLayerNumber.bridge, wid: wid ?? 0, app: snap.bundleID,
                action: .moveToSpace, target: "\(snap.displayUUID)/\(snap.spaceIndex)",
                before: liveSpaceID.map { "space=\($0)" } ?? "-", after: "-", result: .skip,
                reason: reason))
            return PlanItem(snapshotIndex: s, snapshotWindow: snap,
                            action: .skip(reason: reason))
        }
        for (s, snap) in snapshot.windows.enumerated() {
            guard let match = matchBySnapshot[s] else {
                // 未运行应用不启动 / 同应用配不上不猜（spec §6.4a/c）
                let reason = liveBundleIDs.contains(snap.bundleID) ? "unmatched" : "app-not-running"
                plan.append(skipItem(s, snap, reason, wid: nil, liveSpaceID: nil))
                continue
            }
            let lw = live[match.liveIndex]
            if mode == .restore && liveFullscreenWIDs.contains(lw.cgWindowID) {
                // 恢复模式：实况窗在全屏 Space 而快照是普通窗——不桥接、不写几何（display-presets 票 12）
                plan.append(skipItem(s, snap, "live-fullscreen", wid: lw.cgWindowID, liveSpaceID: lw.spaceID))
                continue
            }
            if mode == .undo && liveFullscreenWIDs.contains(lw.cgWindowID) {
                // 撤销第一段（票 16 §8.6）：实况窗卡在后台全屏 Space——本段跳过（计 skip，且计入
                // fullscreenPendingCount），待用户按 Esc 后第二段补完（§5.2 后台退出全屏不可达）
                log?.write(StructuredLog.restoreLine(
                    layer: SpaceLayerNumber.bridge, wid: lw.cgWindowID, app: snap.bundleID,
                    action: .moveToSpace, target: "\(snap.displayUUID)/\(snap.spaceIndex)",
                    before: "space=\(lw.spaceID)", after: "-", result: .skip,
                    reason: "fullscreen-exit-pending"))
                plan.append(PlanItem(snapshotIndex: s, snapshotWindow: snap,
                                     action: .pendingFullscreen(live: lw)))
                continue
            }
            if lw.minimized {
                // L4（票 15，spec §6.5）：实况最小化 → 送回快照 Space 并保持最小化，几何不触碰。
                // 快照 minimized 但实况已展开 → 走常规恢复（终态是否最小化尊重实况，不强行重新最小化）
                let resolved = Self.resolveTargetSpace(
                    displayUUID: snap.displayUUID, snapshotIndex: snap.spaceIndex,
                    snapshotSpaces: snapshot.spaces, entries: entries)
                plan.append(PlanItem(snapshotIndex: s, snapshotWindow: snap, action: .restoreMinimized(
                    live: lw, targetSpace: resolved?.entry, mergedFrom: resolved?.mergedFrom)))
                continue
            }
            guard let targetDisplay = displays.first(where: { $0.uuid == snap.displayUUID }) else {
                plan.append(skipItem(s, snap, "target-display-absent", wid: lw.cgWindowID,
                                     liveSpaceID: lw.spaceID))
                continue
            }
            let resolved = Self.resolveTargetSpace(
                displayUUID: snap.displayUUID, snapshotIndex: snap.spaceIndex,
                snapshotSpaces: snapshot.spaces, entries: entries)
            plan.append(PlanItem(snapshotIndex: s, snapshotWindow: snap, action: .act(
                live: lw, targetSpace: resolved?.entry, mergedFrom: resolved?.mergedFrom,
                targetDisplay: targetDisplay, capturedOrientation: capturedOrientation[snap.displayUUID] ?? 0)))
        }
        return plan
    }

    // MARK: - Pass L2：桥接 Space 移动（屏 + Space 一步到位，spec §6.8）

    private func bridgeMove(_ item: PlanItem, bridgeOK: Bool, failed: inout Set<Int>) {
        guard case .act(let lw, let targetSpace, let mergedFrom, _, _) = item.action else { return }
        let snap = item.snapshotWindow
        let wid = lw.cgWindowID
        let target = "\(snap.displayUUID)/\(targetSpace?.index ?? snap.spaceIndex)"

        guard bridgeOK, let targetSpace else {
            // L2 降级（探针失败 / 运行时 no-op / FORCE_DEGRADED / 无既有 Space 可落）：该层跳过，L1 照常（§6.1）
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.bridge, wid: wid, app: snap.bundleID,
                action: .moveToSpace, target: target, before: "space=\(lw.spaceID)", after: "-", result: .skip))
            // 原因分类：bridgeOK=false = 探针层不可用；targetSpace=nil = 快照目标屏在当前 Space 清单无记录
            log?.write("[restore] detail wid=\(wid) app=\(snap.bundleID) action=move-to-space "
                + "error=l2-skip-cause bridgeOK=\(bridgeOK) targetSpaceNil=\(targetSpace == nil) "
                + "probe=\(spaces.isLayerAvailable(.bridge)) entriesEmpty=\(!bridgeOK && spaces.isBridgeAvailable())")
            return
        }
        if let from = mergedFrom {
            logSpaceMerge(wid: wid, app: snap.bundleID, display: snap.displayUUID,
                          from: from, to: targetSpace.index)
        }
        do {
            let moved = try spaces.moveWindowsToSpace(windowIDs: [wid], spaceID: targetSpace.spaceID)
            // false = perform 后归属未变更（no-op，适配器已记 [degrade] 并标记该层失效）→ 计失败
            if !moved { failed.insert(item.snapshotIndex) }
            if moved && lw.spaceID != targetSpace.spaceID { lastBridgeMoveAt = Date() }
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.bridge, wid: wid, app: snap.bundleID,
                action: .moveToSpace, target: target,
                before: "space=\(lw.spaceID)", after: "space=\(targetSpace.spaceID)",
                result: moved ? .ok : .fail))
        } catch {
            failed.insert(item.snapshotIndex)
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.bridge, wid: wid, app: snap.bundleID,
                action: .moveToSpace, target: target, before: "space=\(lw.spaceID)", after: "-", result: .fail))
            logDetail(wid: wid, app: snap.bundleID, action: .moveToSpace, error: error)
        }
    }

    // MARK: - Pass L1：AX 几何摆位（比例坐标 × 所属屏 CGDisplayBounds，spec §7.2）

    /// place 结局（并发执行后由调用方串行合并共享集合）
    private enum PlaceOutcome {
        case ok
        /// 不尝试也不补写（非 AX 窗口：写必失败，进 pending 只会拖住消费批次）：计 skip
        case skipped
        /// 转延迟几何（后台窗 / AX 写限时超时）：计 skip，消费轮询在窗口可写后单次补写
        case deferred
        case fail
    }

    /// 单窗 AX 写限时执行（超时弃线程；AX 写在系统侧最终会完成或失败，弃线程不影响正确性）
    private func boundedApply(_ apply: @escaping () throws -> Void, timeout: TimeInterval) -> Result<Void, Error> {
        let box = PlaceBox()
        let t = Thread { box.value = Result { try apply() } }
        t.stackSize = 1 << 20
        t.start()
        let deadline = Date().addingTimeInterval(timeout)
        while box.value == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        return box.value ?? .failure(RestoreEngineError.axApplyTimeout)
    }

    private func place(_ item: PlanItem, activeSpaceIDs: Set<Int64>) -> PlaceOutcome {
        guard case .act(let lw, _, _, let targetDisplay, let capturedOrientation) = item.action else { return .ok }
        let snap = item.snapshotWindow
        let wid = lw.cgWindowID

        let current = rotationProvider(targetDisplay.id)
        let swap = (capturedOrientation % 180) != (current % 180)
        let rx = swap ? snap.y : snap.x
        let ry = swap ? snap.x : snap.y
        let rw = swap ? snap.h : snap.w
        let rh = swap ? snap.w : snap.h

        func recordPending(_ why: String) -> PlaceOutcome {
            let entry = PendingGeometryEntry(
                windowID: wid, displayUUID: snap.displayUUID, x: rx, y: ry, w: rw, h: rh)
            l1Lock.lock(); runPendingGeometry.append(entry); l1Lock.unlock()
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.geometry, wid: wid, app: snap.bundleID,
                action: .position, target: snap.displayUUID, before: "-", after: "-", result: .skip))
            log?.write("[restore] detail wid=\(wid) app=\(snap.bundleID) action=position "
                + "error=\(why) detail=deferred-pending")
            return .deferred
        }

        // 后台窗事前判定（精准口径）：窗不在任一屏的活跃 Space → AX 树不含它，打 AX 写只会
        // 4.7s 超时后 elementInvalid（实测 13 项 × 4.7s = 61s）→ 直接进延迟几何，
        // 计 skip（未尝试 ≠ 失败）。isOnscreen（CG 口径）兜底；activeSpaceIDs 空 = 数据源不可用，判定禁用
        if !lw.isOnscreen
            || (!activeSpaceIDs.isEmpty && !activeSpaceIDs.contains(lw.spaceID)) {
            return recordPending("offscreen-deferred")
        }

        let bounds = targetDisplay.bounds
        let position = CGPoint(x: bounds.minX + CGFloat(rx) * bounds.width,
                               y: bounds.minY + CGFloat(ry) * bounds.height)
        let size = CGSize(width: CGFloat(rw) * bounds.width, height: CGFloat(rh) * bounds.height)
        let before = Self.ratioString(x: lw.x, y: lw.y, w: lw.w, h: lw.h)
        let after = Self.ratioString(x: rx, y: ry, w: rw, h: rh)
        let targetLine = "\(snap.displayUUID) rot=\(current)"
        // 写前查：旧补写可在本次写之后落地并注销，写后再查会漏（独占期间新补写不会开写，写前查即完整）
        let deferredInFlight = deferredGeometry.isApplying(windowID: wid)

        switch boundedApply({ try self.geometry.apply(windowID: wid, position: position, size: size) },
                            timeout: Self.axApplyTimeoutSeconds) {
        case .success:
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.geometry, wid: wid, app: snap.bundleID,
                action: .position, target: targetLine, before: before, after: after, result: .ok))
            if deferredInFlight {
                // 排空超时后仍在途的旧补写会在本次写之后落地：记 pending 让下一轮补写重写本轮目标
                let entry = PendingGeometryEntry(
                    windowID: wid, displayUUID: snap.displayUUID, x: rx, y: ry, w: rw, h: rh)
                l1Lock.lock(); runPendingGeometry.append(entry); l1Lock.unlock()
                log?.write("[restore] detail wid=\(wid) app=\(snap.bundleID) action=position "
                    + "error=deferred-in-flight detail=reassert-pending")
            }
            return .ok
        case .failure(RestoreEngineError.axApplyTimeout):
            // 限时内未确认：转延迟几何计 skip（消费轮询在 app 不忙后补写；被弃线程的写若最终
            // 成功则窗口已就位，consumer 补写同值无害）
            return recordPending("ax-apply-timeout")
        case .failure(RestoreEngineError.notAXWindow):
            // 立即放弃且不进 pending：实测这批窗（Chrome 363×89/1920×46 辅助条、Things alpha=0 条）
            // 每轮补写 3/3 必败，每次 ~4.7s 拖住整个消费批次，同批的 WeCom 因此迟到十几秒（11-03）
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.geometry, wid: wid, app: snap.bundleID,
                action: .position, target: snap.displayUUID, before: "-", after: "-", result: .skip,
                reason: "not-ax-window"))
            return .skipped
        case .failure(AXFacadeError.elementInvalid):
            // writer 内部已带元素重建重试，仍元素失效：计 fail，pending 兜底（可见后补写）
            return recordPending("elementInvalid-after-retry")
        case .failure(let error):
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.geometry, wid: wid, app: snap.bundleID,
                action: .position, target: targetLine, before: before, after: after, result: .fail))
            log?.write("[restore] detail wid=\(wid) app=\(snap.bundleID) action=position error=\(error)")
            return .fail
        }
    }

    // MARK: - Pass L3：全屏最后（票 15，spec §6.8 后半 + §5.1 指定屏全屏 + §5.2 进入后台可完成）

    /// 快照 fullscreen Space 逐条恢复：找该应用实况窗 → 目标屏就位（桥接预移位）→ AXFullScreen=true → 等动画。
    /// 全屏 Space(type=4) 由 AXFullScreen 在目标屏后台新建（验收 A17）；进入后台即可完成，不要求该 Space 可见
    /// （§5.2/§8.6：程序化不可达的「后台退出全屏」只咬撤销，票 16 两段式）。
    private func restoreFullscreenSpaces(snapshot: Snapshot, live: [LiveRestoreWindow],
                                         entries: [SpaceEntry], displays: [Displays.Info],
                                         layerOK: Bool, bridgeOK: Bool, mode: RunMode,
                                         ok: inout Int, skipped: inout Int, failed: inout Int,
                                         pending: inout Int) {
        var consumed = Set<UInt32>()  // 同应用多个全屏 Space 时，一个实况窗只消费一次
        for space in snapshot.spaces where space.kind == .fullscreen {
            let target = "\(space.displayUUID)/\(space.index)"
            guard let appID = space.fullscreenAppBundleID, !appID.isEmpty else {
                // 无所属应用可归（快照缺 fullscreenAppBundleID）：per-Space skip 行，wid=0/app=-（文件头扩展键口径）
                log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.fullscreen, wid: 0, app: "-",
                    action: .fullscreen, target: target, before: "-", after: "-", result: .skip,
                    reason: "fullscreen-app-missing"))
                skipped += 1
                continue
            }
            guard displays.contains(where: { $0.uuid == space.displayUUID }) else {
                log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.fullscreen, wid: 0, app: appID,
                    action: .fullscreen, target: target, before: "-", after: "-", result: .skip,
                    reason: "target-display-absent"))
                skipped += 1
                continue
            }
            guard layerOK else {
                // L3 降级（探针失败 / FORCE_DEGRADED=fullscreen）：全屏应用不动，其余层照常（§6.1）
                log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.fullscreen, wid: 0, app: appID,
                    action: .fullscreen, target: target, before: "-", after: "-", result: .skip,
                    reason: "fullscreen-layer-unavailable"))
                skipped += 1
                continue
            }
            guard let lw = live.first(where: { $0.bundleID == appID && !consumed.contains($0.cgWindowID) }) else {
                // 应用已退出不启动（spec §6.4a）
                log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.fullscreen, wid: 0, app: appID,
                    action: .fullscreen, target: target, before: "-", after: "-", result: .skip,
                    reason: "app-not-running"))
                skipped += 1
                continue
            }
            consumed.insert(lw.cgWindowID)
            let wid = lw.cgWindowID
            var before = "fullscreen=false disp=\(lw.displayUUID) space=\(lw.spaceID)"

            // 撤销（票 16 §8.6）：按「是否仍卡在全屏 Space」分流两段式。
            // 卡在目标屏 = 已达标幂等 ok（重复撤销无害）；卡在其它屏 = 后台退出不可达（§5.2），
            // 第一段跳过计 pending（文案 N）；已不在全屏（用户已按 Esc：全屏 Space 销毁、窗口归原 Space）
            // = 第二段补完，进入全屏后台可达（§5.2），落下方常规路径回目标屏重新全屏。
            if mode == .undo {
                let current = entries.first { $0.spaceID == lw.spaceID }
                let stuck = current?.kind == SpaceKind.fullscreen
                before = "fullscreen=\(stuck) disp=\(lw.displayUUID) space=\(lw.spaceID)"
                if stuck {
                    if current?.displayUUID == space.displayUUID {
                        log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.fullscreen, wid: wid,
                            app: appID, action: .fullscreen, target: target, before: before,
                            after: "fullscreen=true", result: .ok))
                        log?.write("[restore] detail wid=\(wid) app=\(appID) action=fullscreen detail=already-at-target")
                        ok += 1
                        continue
                    }
                    log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.fullscreen, wid: wid,
                        app: appID, action: .fullscreen, target: target, before: before,
                        after: "-", result: .skip, reason: "fullscreen-exit-pending"))
                    pending += 1
                    skipped += 1
                    continue
                }
            }

            // 目标屏就位（05 #4：窗口先到目标屏；已在目标屏则免桥接）。预移位落点取目标屏既有 Space 之一即可
            if lw.displayUUID != space.displayUUID {
                guard fullscreenPreMove(wid: wid, appID: appID, displayUUID: space.displayUUID,
                                        target: target, before: &before, entries: entries, bridgeOK: bridgeOK,
                                        skipped: &skipped, failed: &failed) else { continue }
            }

            do {
                try fullscreen.setFullScreen(windowID: wid, true)
                if fullscreenSettleSeconds > 0 { Thread.sleep(forTimeInterval: fullscreenSettleSeconds) }
                log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.fullscreen, wid: wid, app: appID,
                    action: .fullscreen, target: target, before: before, after: "fullscreen=true", result: .ok))
                ok += 1
            } catch {
                failed += 1
                log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.fullscreen, wid: wid, app: appID,
                    action: .fullscreen, target: target, before: before, after: "-", result: .fail))
                logDetail(wid: wid, app: appID, action: .fullscreen, error: error)
            }
        }
    }

    /// L3 目标屏桥接预移位；返回 false = 该条目已处理完（skip/fail 已记）
    private func fullscreenPreMove(wid: UInt32, appID: String, displayUUID: String, target: String,
                                   before: inout String, entries: [SpaceEntry], bridgeOK: Bool,
                                   skipped: inout Int, failed: inout Int) -> Bool {
        // 落点只取用户桌面：别的应用的全屏 Space 不接纳普通窗（display-presets 票 12）
        guard bridgeOK,
              let landing = entries.filter({ $0.displayUUID == displayUUID && $0.kind == SpaceKind.user })
                  .min(by: { $0.index < $1.index }) else {
            // 桥接不可用/目标屏无用户桌面：无法就位（§6.1 L3 失效表现 = 不动；L2 已另有降级日志）
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.fullscreen, wid: wid, app: appID,
                action: .fullscreen, target: target, before: before, after: "-", result: .skip,
                reason: "fullscreen-premove-unavailable"))
            skipped += 1
            return false
        }
        do {
            let moved = try spaces.moveWindowsToSpace(windowIDs: [wid], spaceID: landing.spaceID)
            guard moved else {
                // no-op：桥接失效特征（适配器已记 [degrade]）→ 本窗无法就位，计失败
                log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.fullscreen, wid: wid, app: appID,
                    action: .fullscreen, target: target, before: before, after: "-", result: .fail))
                failed += 1
                return false
            }
            before += " prespace=\(landing.index)"
            return true
        } catch {
            // 桥接层失效连坐（探针未过 / FORCE_DEGRADED）：该全屏窗跳过，不判本窗失败（§6.1 只降不可用层）
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.fullscreen, wid: wid, app: appID,
                action: .fullscreen, target: target, before: before, after: "-", result: .skip))
            skipped += 1
            return false
        }
    }

    // MARK: - Pass L4：最小化窗口恢复（票 15，spec §6.5）

    /// 实况最小化窗口：取消最小化（实测自动落回原 Space，05 #5）→ 按需桥接移至快照 Space → 重新最小化。
    /// 先试最小化状态直接桥接（实测可行则省去首尾，语义不变）；失败不做运行时 no-op 标记，回退路径仍可用。
    /// L4 不可用（探针 / FORCE_DEGRADED=minimized）时原地保持最小化不动，不报失败（skip，§6.1/§6.5）。
    private func restoreMinimizedWindow(_ item: PlanItem, layerOK: Bool,
                                        ok: inout Int, skipped: inout Int, failed: inout Int) {
        guard case .restoreMinimized(let lw, let targetSpace, let mergedFrom) = item.action else { return }
        let snap = item.snapshotWindow
        let wid = lw.cgWindowID
        let target = "\(snap.displayUUID)/\(targetSpace?.index ?? snap.spaceIndex)"
        let before = "minimized=true space=\(lw.spaceID)"

        guard layerOK else {
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.minimized, wid: wid, app: snap.bundleID,
                action: .minimize, target: target, before: before, after: "-", result: .skip))
            skipped += 1
            return
        }
        guard let targetSpace else {
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.minimized, wid: wid, app: snap.bundleID,
                action: .minimize, target: target, before: before, after: "-", result: .skip,
                reason: "target-display-absent"))
            skipped += 1
            return
        }
        if let from = mergedFrom {
            logSpaceMerge(wid: wid, app: snap.bundleID, display: snap.displayUUID,
                          from: from, to: targetSpace.index)
        }

        // §6.5：先试最小化状态下直接桥接（实现期可简化，语义不变）
        let direct: Bool?
        do { direct = try spaces.tryMoveMinimized(windowID: wid, spaceID: targetSpace.spaceID) }
        catch { direct = nil }
        if direct == true {
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.minimized, wid: wid, app: snap.bundleID,
                action: .minimize, target: target, before: before,
                after: "minimized=true space=\(targetSpace.spaceID)", result: .ok))
            ok += 1
            return
        }

        // 回退路径：取消最小化 → 桥接移至快照 Space → 重新最小化（终态 = 原地保持最小化，无论移窗成败）
        do {
            try minimize.setMinimized(windowID: wid, false)
            var moved: Bool?
            var layerUnavailable = false
            var bridgeError: Error?
            do { moved = try spaces.moveWindowsToSpace(windowIDs: [wid], spaceID: targetSpace.spaceID) }
            catch let e as SpaceAdapterError where e == .layerUnavailable(.bridge) {
                // 桥接层失效连坐（探针未过 / 运行时 no-op 已标死）：窗口已重最小化原地保持，不判本窗失败
                layerUnavailable = true
            }
            catch { bridgeError = error }
            var reMinimized = true
            do { try minimize.setMinimized(windowID: wid, true) } catch { reMinimized = false }

            if let moved {
                if moved && reMinimized {
                    log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.minimized, wid: wid,
                        app: snap.bundleID, action: .minimize, target: target, before: before,
                        after: "minimized=true space=\(targetSpace.spaceID)", result: .ok))
                    ok += 1
                } else {
                    // no-op（同 L2 口径计失败）或重最小化写失败（终态偏差）
                    failed += 1
                    log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.minimized, wid: wid,
                        app: snap.bundleID, action: .minimize, target: target, before: before,
                        after: "-", result: .fail))
                }
            } else if layerUnavailable {
                skipped += 1
                log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.minimized, wid: wid,
                    app: snap.bundleID, action: .minimize, target: target, before: before,
                    after: "minimized=true space=\(lw.spaceID)", result: .skip))
            } else {
                failed += 1
                log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.minimized, wid: wid,
                    app: snap.bundleID, action: .minimize, target: target, before: before,
                    after: "-", result: .fail))
                if let bridgeError {
                    logDetail(wid: wid, app: snap.bundleID, action: .minimize, error: bridgeError)
                }
            }
        } catch {
            // 取消最小化写失败：窗口保持最小化原地，计失败
            failed += 1
            log?.write(StructuredLog.restoreLine(layer: SpaceLayerNumber.minimized, wid: wid, app: snap.bundleID,
                action: .minimize, target: target, before: before, after: "-", result: .fail))
            logDetail(wid: wid, app: snap.bundleID, action: .minimize, error: error)
        }
    }

    /// A12：快照用户桌面多出 → 并入同屏最后一个实况用户桌面（spec §6.7 不补建；L2/L4 共用，票 12 按用户桌面序号）
    private func logSpaceMerge(wid: UInt32, app: String, display: String, from snapshotIndex: Int, to index: Int) {
        log?.write("[restore] space-merge wid=\(wid) app=\(app) display=\(display) "
            + "snapshotIndex=\(snapshotIndex) mergedTo=\(index)")
    }

    // MARK: - 实况收集

    /// CG 采样 → 恢复集合：单 Space 归属（粘性/辅助窗排除）、屏归属与比例几何走 Core.LiveWindowLocator、
    /// 离屏候选读 AX minimized
    private func collectLiveWindows(samples: [CGWindowSample], displays: [Displays.Info],
                                    entries: [SpaceEntry]) -> [LiveRestoreWindow] {
        let spaceByWindow = (try? spaces.spaceIDsByWindowID()) ?? [:]
        let located = LiveWindowLocator.locate(samples: samples, displays: displays,
                                               spaceIDByWindow: spaceByWindow, spaceEntries: entries)
        return located.compactMap { lw in
            let sample = lw.sample
            guard let spaceID = spaceByWindow[sample.windowID] else { return nil }
            let minimized = !sample.isOnscreen && ax.probe(pid: sample.pid, windowID: sample.windowID).minimized
            return LiveRestoreWindow(
                cgWindowID: sample.windowID, bundleID: sample.bundleID, title: sample.title ?? "",
                displayUUID: lw.display.uuid ?? "", spaceID: spaceID,
                x: lw.x, y: lw.y, w: lw.w, h: lw.h,
                minimized: minimized,
                isOnscreen: sample.isOnscreen)
        }
    }

    // MARK: - 辅助

    /// 普通窗目标 Space（L2 与 L4 共用；display-presets 票 12，spec §5.3/§6.7）。只在同屏用户桌面中选，
    /// 全屏 Space 永不作为普通窗目标（全屏 Space 与桌面可被用户重排，绝对 index 会错位，验收4 实测）：
    ///   快照窗所在 Space 是用户桌面 → 取它在快照同屏用户桌面中的序号 k → 实况同屏第 k 个用户桌面；
    ///   实况用户桌面不足 → 就近并入最后一个（mergedFrom = 快照 index，不补建）；
    ///   快照无该 Space 记录（或记为全屏，旧预设数据）→ 按 index 在实况用户桌面中定位，不命中就近并入；
    ///   目标屏无用户桌面 → nil。现状多出（A13）无需特判：第 k 个照常命中。
    static func resolveTargetSpace(displayUUID: String, snapshotIndex: Int, snapshotSpaces: [SnapshotSpace],
                                   entries: [SpaceEntry]) -> (entry: SpaceEntry, mergedFrom: Int?)? {
        let liveDesktops = entries
            .filter { $0.displayUUID == displayUUID && $0.kind == SpaceKind.user }
            .sorted { $0.index < $1.index }
        guard let last = liveDesktops.last else { return nil }
        let snapshotDesktops = snapshotSpaces
            .filter { $0.displayUUID == displayUUID && $0.kind == .user }
            .map(\.index).sorted()
        if let ordinal = snapshotDesktops.firstIndex(of: snapshotIndex) {
            return ordinal < liveDesktops.count ? (liveDesktops[ordinal], nil) : (last, snapshotIndex)
        }
        if let exact = liveDesktops.first(where: { $0.index == snapshotIndex }) {
            return (exact, nil)
        }
        let nearest = liveDesktops.min { abs($0.index - snapshotIndex) < abs($1.index - snapshotIndex) } ?? last
        return (nearest, snapshotIndex)
    }

    static func ratioString(x: Double, y: Double, w: Double, h: Double) -> String {
        "(\(String(format: "%.4f", x)),\(String(format: "%.4f", y)),\(String(format: "%.4f", w)),\(String(format: "%.4f", h)))"
    }

    /// 失败详情行（spec §6.3「失败详情进日志」；§10.4 主行格式保持原样，详情独立成行）
    private func logDetail(wid: UInt32, app: String, action: RestoreAction, error: Error) {
        log?.write("[restore] detail wid=\(wid) app=\(app) action=\(action.rawValue) error=\(error)")
    }
}

/// 恢复降级阶梯层号（L1 几何 / L2 桥接 / L3 全屏 / L4 最小化，spec §6.1）
enum SpaceLayerNumber {
    static let geometry = 1
    static let bridge = 2
    static let fullscreen = 3
    static let minimized = 4
}

private extension URL {
    /// 日志用短路径「<拓扑键>/<文件名>」（回滚快照文件名各拓扑同名，须带目录才可区分）
    var topologyRelativePath: String {
        "\(deletingLastPathComponent().lastPathComponent)/\(lastPathComponent)"
    }
}
