import AppKit
import ApplicationServices
import Core
import CoreGraphics
import Foundation

// SpaceAdapter.swift — 私有集中层（票 13 拥有本文件，spec §10.1/§10.2）。
// 职责：SLSCopyManagedDisplaySpaces 枚举、SLSCopySpacesForWindows 窗口→Space（最小化报原 Space）、
//       SLSBridgedMoveWindowsToManagedSpaceOperation 桥接移窗（教料书 C 入口 SLSMoveWindowsToManagedSpace
//       对他人窗口是静默 no-op，spec §5.2 已证伪，禁止使用）、启动探针（按层）、
//       运行时 no-op 识别（perform 后校验归属实际变更）、LAYOUTFIXER_FORCE_DEGRADED 层粒度钩子。
// 层映射（恢复降级阶梯，spec §6.1）：bridge=L2、fullscreen=L3、 minimized=L4。
// SkyLight 全部经 dlopen/dlsym 加载，零链接期依赖（照 05 spike 实测写法）。

/// 恢复能力层（降级阶梯 L2–L4；L1 AX 几何在 AXFacade，不经本模块探针）
public enum SpaceLayer: String, Sendable, CaseIterable {
    /// L2 桥接移窗（跨 Space / 跨屏）
    case bridge
    /// L3 全屏进入（AXFullScreen + 桥接预移位）
    case fullscreen
    /// L4 最小化恢复（AXMinimized + 按需桥接）
    case minimized

    /// spec §10.4 日志行里的层号
    public var layerNumber: Int {
        switch self {
        case .bridge: return 2
        case .fullscreen: return 3
        case .minimized: return 4
        }
    }
}

/// 单层探测结果（app 侧能力状态行数据源，spec §8.5）
public struct LayerProbe: Equatable, Sendable {
    public let layer: SpaceLayer
    public let available: Bool
    /// 不可用原因（probe-miss / no-op），可用时为空
    public let reason: String
    public let detail: String

    public init(layer: SpaceLayer, available: Bool, reason: String = "", detail: String = "") {
        self.layer = layer
        self.available = available
        self.reason = reason
        self.detail = detail
    }
}

public enum SpaceAdapterError: Error, Equatable, Sendable {
    /// SkyLight 私有符号加载失败（版本守卫路径，不崩溃）
    case skyLightUnavailable
    /// SLS 调用返回空/失败
    case slsFailed(String)
    /// 桥接操作类/选择器缺失或执行失败
    case bridgedOpFailed(String)
    /// 目标层已失效（探针未过 / 运行时 no-op / FORCE_DEGRADED 强制）
    case layerUnavailable(SpaceLayer)
}

/// 有界执行的跨线程结果盒（Swift 泛型函数内不可嵌套类）
private final class BoundedResultBox<T: Sendable>: @unchecked Sendable {
    var value: Result<T, Error>?
}

public final class SpaceAdapter: SpaceProviding, @unchecked Sendable {
    // MARK: - SkyLight 私有绑定（dlopen，无链接期依赖，照 spike）

    struct SkyLightAPI {
        let connectionID: Int32
        let copyManagedDisplaySpaces: (@convention(c) (Int32) -> CFArray?)?
        let copySpacesForWindows: (@convention(c) (Int32, Int, CFArray) -> CFArray?)?
        let copyManagedDisplayForWindow: (@convention(c) (Int32, UInt32) -> CFString?)?
        let spaceGetType: (@convention(c) (Int32, UInt64) -> Int32)?
    }

    private static func loadSym<T>(_ lib: String, _ name: String, as type: T.Type) -> T? {
        let h = lib.isEmpty ? dlopen(nil, RTLD_LAZY) : dlopen(lib, RTLD_LAZY)
        guard let hh = h, let p = dlsym(hh, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    private static let skyLight: SkyLightAPI? = {
        let lib = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let conn = loadSym(lib, "SLSMainConnectionID", as: (@convention(c) () -> Int32).self) else { return nil }
        return SkyLightAPI(
            connectionID: conn(),
            copyManagedDisplaySpaces: loadSym(lib, "SLSCopyManagedDisplaySpaces", as: (@convention(c) (Int32) -> CFArray?).self),
            copySpacesForWindows: loadSym(lib, "SLSCopySpacesForWindows", as: (@convention(c) (Int32, Int, CFArray) -> CFArray?).self),
            copyManagedDisplayForWindow: loadSym(lib, "SLSCopyManagedDisplayForWindow", as: (@convention(c) (Int32, UInt32) -> CFString?).self),
            spaceGetType: loadSym(lib, "SLSSpaceGetType", as: (@convention(c) (Int32, UInt64) -> Int32).self)
        )
    }()

    /// 桥接操作类可用性诊断（nil = 可用；否则为缺失细节）
    private static func bridgeOpClassIssue() -> String? {
        guard let cls = NSClassFromString(Self.bridgeOpClassName) as? NSObject.Type else { return "class missing" }
        guard class_getInstanceMethod(cls, NSSelectorFromString("initWithWindows:spaceID:")) != nil else {
            return "selector initWithWindows:spaceID: missing"
        }
        guard class_getInstanceMethod(cls, NSSelectorFromString("performWithWMBridgeDelegate")) != nil else {
            return "selector performWithWMBridgeDelegate missing"
        }
        return nil
    }

    private static let bridgeOpClassName = "SLSBridgedMoveWindowsToManagedSpaceOperation"

    /// CFNumber(wid) 数组 → CFArray（spike 同款）
    private static func windowIDArray(_ wids: [UInt32]) -> CFArray {
        let nums: [CFNumber] = wids.map { var v = Int32(bitPattern: $0); return CFNumberCreate(nil, .intType, &v)! }
        return nums as NSArray as CFArray
    }

    private static func cfInt64(_ v: Any?) -> Int64? {
        guard let n = v as? NSNumber else { return nil }
        var out: Int64 = 0
        return CFNumberGetValue(n as CFNumber, .sInt64Type, &out) ? out : nil
    }

    // MARK: - 状态

    /// 移窗后等待 WindowServer 结算再校验归属的时长（spike 实测 1.2s 足够）
    private let settleSeconds: TimeInterval
    /// 可注入的 spaceIDs 读取器（nil = 直连 SkyLight；单测注入假读/阻塞读）
    var spaceReader: ((UInt32) throws -> [Int64])?

    private let log: LogWriting?
    private let lock = NSLock()
    /// 运行时识别为 no-op 而失效的层（lock 保护；进程内不可逆，需重启 app 重探）
    nonisolated(unsafe) private var runtimeNoOpLayers: Set<SpaceLayer> = []

    /// LAYOUTFIXER_FORCE_DEGRADED=bridge|fullscreen|minimized（spec §10.2 探测钩子，层粒度）
    static let forcedDegradedLayer: SpaceLayer? = {
        guard let raw = ProcessInfo.processInfo.environment["LAYOUTFIXER_FORCE_DEGRADED"], !raw.isEmpty else { return nil }
        return SpaceLayer(rawValue: raw)
    }()

    /// - Parameters:
    ///   - log: 结构化日志 sink（[degrade] 行经 Core.StructuredLog 格式化写出）
    ///   - settleSeconds: 桥接移窗后校验归属前的等待（默认 1.2s，spike 实测）
    public init(log: LogWriting? = nil, settleSeconds: TimeInterval = 1.2, spaceReader: ((UInt32) throws -> [Int64])? = nil) {
        self.log = log
        self.settleSeconds = settleSeconds
        self.spaceReader = spaceReader
        // 钩子生效即记 [degrade] probe-miss（验收路径：FORCE_DEGRADED=bridge → L2 不可用 + 日志出现）
        if let f = Self.forcedDegradedLayer {
            log?.write(StructuredLog.degradeLine(
                layer: f.layerNumber,
                reason: "probe-miss",
                detail: "forced by LAYOUTFIXER_FORCE_DEGRADED=\(f.rawValue)"
            ))
        }
    }

    // MARK: - 启动探针（spec §10.2：类存在性 + SLS 符号可用性，按层报告，失败不崩溃）

    /// 全部层探测（能力状态行数据源）
    public func probeLayers() -> [LayerProbe] {
        SpaceLayer.allCases.map(probeLayer)
    }

    /// 单层探测：FORCE_DEGRADED > 运行时 no-op > 结构性探测（SLS 符号 / 桥接类 / AX 权限）
    public func probeLayer(_ layer: SpaceLayer) -> LayerProbe {
        if Self.forcedDegradedLayer == layer {
            return LayerProbe(layer: layer, available: false, reason: "probe-miss",
                              detail: "forced by LAYOUTFIXER_FORCE_DEGRADED=\(layer.rawValue)")
        }
        lock.lock()
        let noOp = runtimeNoOpLayers.contains(layer)
        lock.unlock()
        if noOp {
            return LayerProbe(layer: layer, available: false, reason: "no-op",
                              detail: "bridged move observed silent no-op earlier in this session")
        }
        guard Self.skyLight != nil else {
            return LayerProbe(layer: layer, available: false, reason: "probe-miss", detail: "SkyLight symbols unavailable")
        }
        switch layer {
        case .bridge:
            if let issue = Self.bridgeOpClassIssue() {
                return LayerProbe(layer: layer, available: false, reason: "probe-miss", detail: issue)
            }
        case .fullscreen:
            // L3 = 桥接预移位到目标屏 + AXFullScreen 写，桥接类存在是结构前提
            //（AX 权限缺失不影响「层可用性」定性，归票 18 未就绪门控，这里仅附注）
            if let issue = Self.bridgeOpClassIssue() {
                return LayerProbe(layer: layer, available: false, reason: "probe-miss", detail: "bridge pre-move: \(issue)")
            }
        case .minimized:
            break // L4 结构需求 = SLS 符号（已验），AXMinimized 写的权限状态附注如下
        }
        var detail = ""
        if !AXIsProcessTrusted() { detail = "AX permission not granted to this process (pipeline gate: ticket 18)" }
        return LayerProbe(layer: layer, available: true, detail: detail)
    }

    /// 层可用性速查（恢复管线降级阶梯用）
    public func isLayerAvailable(_ layer: SpaceLayer) -> Bool {
        probeLayer(layer).available
    }

    // MARK: - SpaceProviding（Core/Seams.swift 冻结接缝）

    /// SLSCopyManagedDisplaySpaces 展开：每屏 1 起 index，kind 0=用户桌面 4=全屏（spec §5.1 实测）
    public func managedSpaces() throws -> [SpaceEntry] {
        try SpaceAdapter.bounded(timeout: Self.bridgeReadTimeoutSeconds) { [self] in
            var out: [SpaceEntry] = []
            for display in try managedDisplays() {
                out.append(contentsOf: display.spaces)
            }
            return out
        }
    }

    /// CGWindowID → spaceID；最小化窗口报原 Space（spec §5.1 实测）。
    /// 无归属辅助窗（0 个 Space）与多 Space 粘性窗（>1 个）均不入表（spec §5.3 排除出恢复集合）。
    public func spaceIDsByWindowID() throws -> [UInt32: Int64] {
        try SpaceAdapter.bounded(timeout: Self.bridgeReadTimeoutSeconds) { [self] in
            var out: [UInt32: Int64] = [:]
            for wid in Self.windowListWindowIDs() {
                let ids = try spaceIDs(windowID: wid)
                if ids.count == 1 { out[wid] = ids[0] }
            }
            return out
        }
    }

    // MARK: - 只读查询（票 14/15 恢复管线与调试命令共用）

    private struct ManagedDisplaySpaces {
        let uuid: String
        let spaces: [SpaceEntry]
        let currentSpaceID: Int64
    }

    /// SLSCopyManagedDisplaySpaces 原始展开（保留分屏结构与 Current Space）
    private func managedDisplays() throws -> [ManagedDisplaySpaces] {
        guard let sl = Self.skyLight, let copy = sl.copyManagedDisplaySpaces else { throw SpaceAdapterError.skyLightUnavailable }
        guard let cf = copy(sl.connectionID) else { throw SpaceAdapterError.slsFailed("SLSCopyManagedDisplaySpaces returned nil") }
        var out: [ManagedDisplaySpaces] = []
        for e in cf as NSArray {
            guard let d = e as? NSDictionary else { continue }
            let uuid = d["Display Identifier"] as? String ?? "?"
            let current = (d["Current Space"] as? NSDictionary).flatMap { Self.cfInt64($0["id64"]) } ?? 0
            var spaces: [SpaceEntry] = []
            var index = 1 // 每屏 1 起（快照 schema spaceIndex 引用）
            for s in (d["Spaces"] as? NSArray ?? []) {
                guard let sd = s as? NSDictionary else { continue }
                let id64 = Self.cfInt64(sd["id64"]) ?? 0
                // 键名随版本变化（本机 15.8.2 为小写 type），双拼写 + SLSSpaceGetType 兑底（spike 同款）
                let kind = Int(Self.cfInt64(sd["type"])
                    ?? Self.cfInt64(sd["Type"])
                    ?? Int64(sl.spaceGetType?(sl.connectionID, UInt64(id64)) ?? -1)) // 实测 0=用户桌面 4=全屏
                spaces.append(SpaceEntry(spaceID: id64, displayUUID: uuid, index: index, kind: kind))
                index += 1
            }
            out.append(ManagedDisplaySpaces(uuid: uuid, spaces: spaces, currentSpaceID: current))
        }
        return out
    }

    /// displayUUID → 当前 Space id64
    public func currentSpaceIDs() throws -> [String: Int64] {
        var out: [String: Int64] = [:]
        for display in try managedDisplays() { out[display.uuid] = display.currentSpaceID }
        return out
    }

    /// 单窗口 Space 归属（SLSCopySpacesForWindows cid, 0x7；空数组 = 无归属辅助窗，
    /// 多元素 = 多 Space 粘性窗，spec §5.3）
    public func spaceIDs(windowID wid: UInt32) throws -> [Int64] {
        guard let sl = Self.skyLight, let copy = sl.copySpacesForWindows else { throw SpaceAdapterError.skyLightUnavailable }
        guard let res = copy(sl.connectionID, 0x7, Self.windowIDArray([wid])) else {
            throw SpaceAdapterError.slsFailed("SLSCopySpacesForWindows returned nil for wid=\(wid)")
        }
        return (res as NSArray).compactMap { Self.cfInt64($0) }
    }

    /// 单窗口所属显示器稳定 UUID（SLSCopyManagedDisplayForWindow）
    public func displayUUID(windowID wid: UInt32) throws -> String? {
        guard let sl = Self.skyLight, let copy = sl.copyManagedDisplayForWindow else { throw SpaceAdapterError.skyLightUnavailable }
        guard let cf = copy(sl.connectionID, wid) else { return nil }
        return cf as String
    }

    /// 全部 layer-0 常规窗口的 CGWindowID（CGWindowListCopyWindowInfo，公开 API）
    static func windowListWindowIDs() -> [UInt32] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard (w["kCGWindowLayer"] as? Int) == 0, let n = w["kCGWindowNumber"] as? Int else { return nil }
            return UInt32(n)
        }
    }

    // MARK: - 桥接移窗（L2，spec §5.1 实测可用形态）

    /// 桥接移窗到目标 Space，并做运行时 no-op 识别（spec §10.2）。
    /// - Returns: true = 归属实际变更（或窗口已在目标 Space）；false = perform 后归属未变更（no-op，
    ///   已记 [degrade] layer=L2 reason=no-op 并将 bridge 层标记失效）
    /// - Throws: `SpaceAdapterError.layerUnavailable(.bridge)`（探针未过 / 已失效 / FORCE_DEGRADED）
    @discardableResult
    public func moveWindowsToSpace(windowIDs wids: [UInt32], spaceID: Int64) throws -> Bool {
        guard isLayerAvailable(.bridge) else { throw SpaceAdapterError.layerUnavailable(.bridge) }
        var before: [[Int64]] = []
        for wid in wids {
            guard let ids = Self.spaceIDsBounded(wid, timeout: Self.bridgeReadTimeoutSeconds,
                                                 reader: spaceReader ?? { [weak self] in try self!.spaceIDs(windowID: $0) }) else {
                markRuntimeNoOp(reason: "bridge-timeout",
                                detail: "space-read wid=\(wid) waited=\(Int(Self.bridgeReadTimeoutSeconds))s")
                throw SpaceAdapterError.layerUnavailable(.bridge)
            }
            before.append(ids)
        }
        // 已在目标 Space：无事可做，不视为 no-op
        if before.allSatisfy({ $0 == [spaceID] }) { return true }

        // 限时执行：防单窗 WindowServer 长阻塞拖死整轮（实测 159s/111s）；超时标记该层失效
        // （本轮剩余桥接项快速跳过，防后续 SLS 查询被同一棋死拖住）；服务端迁移通常最终完成
        switch Self.performBridgedMoveBounded(wids, spaceID: UInt64(spaceID), timeout: Self.bridgeOpTimeoutSeconds) {
        case .completed(let issue):
            if let issue { throw SpaceAdapterError.bridgedOpFailed(issue) }
        case .timedOut:
            markRuntimeNoOp(reason: "bridge-timeout",
                            detail: "wids=\(wids) target=\(spaceID) waited=\(Int(Self.bridgeOpTimeoutSeconds))s")
        }
        Thread.sleep(forTimeInterval: settleSeconds)

        var changed = false
        for (i, wid) in wids.enumerated() {
            guard let ids = Self.spaceIDsBounded(wid, timeout: Self.bridgeReadTimeoutSeconds,
                                                 reader: spaceReader ?? { [weak self] in try self!.spaceIDs(windowID: $0) }) else {
                markRuntimeNoOp(reason: "bridge-timeout",
                                detail: "verify-read wid=\(wid) waited=\(Int(Self.bridgeReadTimeoutSeconds))s")
                changed = false
                break
            }
            if ids != before[i] { changed = true }
        }
        if !changed {
            markRuntimeNoOp(detail: "attribution unchanged after perform wids=\(wids) target=\(spaceID)")
            return false
        }
        return true
    }

    /// 桥接操作执行器（spike moveto 实测形态）：
    /// NSClassFromString → class_createInstance → IMP 调 initWithWindows:spaceID: → performWithWMBridgeDelegate。
    /// 返回 nil = 已执行；否则为失败细节。
    /// 桥接操作限时执行的结局
    enum BridgedOutcome { case completed(issue: String?); case timedOut }

    /// 桥接操作超时上限（秒）：performBridgedMove 是无超时同步私有 API，
    /// 实测 WindowServer 迁移单窗可阻塞 159s 拖死整轮恢复；专用线程 + 信号量限界，
    /// 超时后放弃等待继续管线（服务端迁移通常最终完成，归属校验以实测为准）
    static let bridgeOpTimeoutSeconds: TimeInterval = 8
    /// SkyLight 读取超时（秒）：楔死时 spaceIDs 查询同样长时间阻塞（实测 111s），一并限界
    static let bridgeReadTimeoutSeconds: TimeInterval = 5

    /// 通用有界执行：楔死的 SkyLight 调用无法中断，只能弃线程继续（超时抛 slsFailed）
    static func bounded<T: Sendable>(
        timeout: TimeInterval, work: @escaping @Sendable () throws -> T
    ) throws -> T {
        let box = BoundedResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = Result { try work() }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) != .timedOut, let result = box.value else {
            throw SpaceAdapterError.slsFailed("bounded-read timeout \(timeout)s")
        }
        return try result.get()
    }

    /// SkyLight spaceIDs 有界读取（楔死时该查询同样阻塞；reader 注入便于单测）
    /// 返回 nil = 超时（未知归属）
    static func spaceIDsBounded(
        _ wid: UInt32, timeout: TimeInterval,
        reader: @escaping (UInt32) throws -> [Int64]
    ) -> [Int64]? {
        final class Box: @unchecked Sendable { var ids: [Int64]? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.ids = try? reader(wid)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut { return nil }
        return box.ids
    }

    /// 限时包装（runner 注入便于单测；生产直通 performBridgedMove）
    static func performBridgedMoveBounded(
        _ wids: [UInt32], spaceID: UInt64, timeout: TimeInterval,
        runner: @escaping ([UInt32], UInt64) -> String? = { SpaceAdapter.performBridgedMove($0, spaceID: $1) }
    ) -> BridgedOutcome {
        final class Box: @unchecked Sendable { var issue: String? }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.issue = runner(wids, spaceID)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return .timedOut
        }
        return .completed(issue: box.issue)
    }

    static func performBridgedMove(_ wids: [UInt32], spaceID: UInt64) -> String? {
        guard let cls = NSClassFromString(bridgeOpClassName) as? NSObject.Type else { return "class missing" }
        let initSel = NSSelectorFromString("initWithWindows:spaceID:")
        guard let method = class_getInstanceMethod(cls, initSel) else { return "selector initWithWindows:spaceID: missing" }
        guard let alloc = class_createInstance(cls, 0) as AnyObject? else { return "class_createInstance failed" }
        typealias InitFn = @convention(c) (AnyObject, Selector, AnyObject, UInt64) -> AnyObject
        let windows = wids.map { NSNumber(value: $0) } as NSArray
        let op = unsafeBitCast(method_getImplementation(method), to: InitFn.self)(alloc, initSel, windows, spaceID)
        let performSel = NSSelectorFromString("performWithWMBridgeDelegate")
        guard let performMethod = class_getInstanceMethod(type(of: op), performSel) else {
            return "selector performWithWMBridgeDelegate missing"
        }
        typealias PerformFn = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(method_getImplementation(performMethod), to: PerformFn.self)(op, performSel)
        return nil
    }

    /// 运行时 no-op 识别：标记该层失效 + [degrade] 日志（spec §10.2，静默 no-op 是失效特征）
    private func markRuntimeNoOp(reason: String = "no-op", detail: String) {
        lock.lock()
        runtimeNoOpLayers.insert(.bridge)
        lock.unlock()
        log?.write(StructuredLog.degradeLine(layer: SpaceLayer.bridge.layerNumber, reason: reason, detail: detail))
    }
}
