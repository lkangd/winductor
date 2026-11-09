import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// PermissionMonitor.swift — 权限观察者（票 18，spec §4.6/§8.3/§8.4）。
// 职责：每 2s 检测两项硬前置授权的现状并对外发状态变化（§8.3「每 2 秒自动检测」）；
//       运行中屏幕录制标题从可读变全空 → 需重新确认信号（§8.4，降回未就绪）。
// 检测函数全部可注入（单测 fake 驱动；默认实现只探测现状，辅助功能不主动弹窗）。

public final class PermissionMonitor {
    // MARK: 模型

    /// 两项硬前置授权（spec §4.6；引导顺序 = 枚举声明序）
    public enum Kind: String, CaseIterable, Sendable {
        case accessibility   // 辅助功能
        case screenCapture   // 屏幕与系统录音
    }

    /// 权限现状（checkNow 刷新）
    public struct Status: Equatable {
        public let accessibilityGranted: Bool
        /// CGPreflightScreenCaptureAccess 现状
        public let screenCaptureGranted: Bool
        /// §8.4：运行中标题从可读变全空 → 需重新确认（未就绪；重新可读且预检通过则解除）
        public let screenCaptureNeedsReconfirm: Bool

        /// 两项齐备且无重确认信号 = 就绪（spec §4.6）
        public var isReady: Bool {
            accessibilityGranted && screenCaptureGranted && !screenCaptureNeedsReconfirm
        }

        /// 缺失项，按引导顺序（辅助功能 → 屏幕录音）
        public var missing: [Kind] {
            var out: [Kind] = []
            if !accessibilityGranted { out.append(.accessibility) }
            if !screenCaptureGranted || screenCaptureNeedsReconfirm { out.append(.screenCapture) }
            return out
        }
    }

    /// 单项授权检测函数（无副作用，只探测现状）
    public typealias Probe = () -> Bool
    /// 屏幕录制重确认探测的标题采样（kCGWindowName 列表；nil = 不可读）
    public typealias TitleSampler = () -> [String?]

    // MARK: 常量与默认实现

    /// 检测周期（spec §8.3「每 2 秒自动检测」）
    public static let pollInterval: TimeInterval = 2.0

    // MARK: 状态

    private let lock = NSLock()
    private var currentStatus: Status
    private let accessibilityProbe: Probe
    private let screenCaptureProbe: Probe
    private let titleSampler: TitleSampler
    private let pollInterval: TimeInterval
    /// 上次标题采样是否有可读标题（nil = 尚无样本；§8.4 前后对比的「之前」）
    private var previousTitlesReadable: Bool?
    private var pollTimer: DispatchSourceTimer?
    /// 首检现状是否已通知（首检无论与初始哨兵是否一致都通知，供接线方建立 UI 基线）
    private var hasNotifiedBaseline = false

    /// 当前权限现状（主线程读；checkNow 刷新）
    public var status: Status {
        lock.lock(); defer { lock.unlock() }
        return currentStatus
    }

    /// 状态变化回调（checkNow 调用线程同步调用；定时路径由 start 投递主线程）。
    /// 首次检测总通知一次（建立基线），此后仅状态变化时通知。
    public var onStatusChange: ((Status) -> Void)?
    /// 追加的状态变化观察者（主窗口通用页状态点等，ui-refactor 票 03）：与 onStatusChange 同时机、同线程，在其后调用
    private var statusObservers: [(Status) -> Void] = []

    /// 追加状态变化观察者（不替换 onStatusChange 的门控接线；只增不删，随监视器生命周期）
    public func addStatusObserver(_ observer: @escaping (Status) -> Void) {
        statusObservers.append(observer)
    }

    // 默认实现直接内联在 init 缺省参数（public 缺省参数须在调用方可见）。
    // 辅助功能：AXIsProcessTrustedWithOptions 不主动弹窗（spec §4.6 检测现状）；
    // 屏幕录制：CGPreflightScreenCaptureAccess；标题采样：CGWindowListCopyWindowInfo(.optionAll)。
    public init(accessibilityProbe: @escaping Probe = {
                    AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
                },
                screenCaptureProbe: @escaping Probe = {
                    CGPreflightScreenCaptureAccess()
                },
                titleSampler: @escaping TitleSampler = {
                    let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
                    return raw.map { $0[kCGWindowName as String] as? String }
                },
                pollInterval: TimeInterval = PermissionMonitor.pollInterval) {
        self.accessibilityProbe = accessibilityProbe
        self.screenCaptureProbe = screenCaptureProbe
        self.titleSampler = titleSampler
        self.pollInterval = pollInterval
        // 初始哨兵 = 未就绪（失败安全）：首次检测前任何读取（如引擎就绪门）都关闸，
        // 而不是默认放行。start() 的立即首检会把状态拉回真实现状。
        self.currentStatus = Status(accessibilityGranted: false, screenCaptureGranted: false,
                                    screenCaptureNeedsReconfirm: false)
    }

    deinit { stop() }

    // MARK: 生命周期

    /// 立即检测一次，并启动每 2s 定时检测（回调投递主线程，供 UI 接线）
    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "winductor.permission-monitor.poll"))
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.checkNow() }
        }
        timer.resume()
        pollTimer = timer
        checkNow()
    }

    public func stop() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    // MARK: 检测

    /// 检测一次并返回现状；状态变化时同步发 onStatusChange（测试与定时共用入口）
    @discardableResult
    public func checkNow() -> Status {
        let accessibilityGranted = accessibilityProbe()
        let screenCaptureGranted = screenCaptureProbe()
        // §8.4 前后对比：之前有可读标题、现在有窗口但标题全空 → 匹配键失效，降回未就绪
        let titles = titleSampler()
        let titlesReadable = titles.contains { !($0 ?? "").isEmpty }
        let lapseDetected = (previousTitlesReadable == true) && !titles.isEmpty && !titlesReadable
        previousTitlesReadable = titlesReadable

        lock.lock()
        let old = currentStatus
        var needsReconfirm = old.screenCaptureNeedsReconfirm || lapseDetected
        if needsReconfirm, screenCaptureGranted, titlesReadable {
            needsReconfirm = false  // 能力真恢复（预检通过且标题重新可读），解除重确认信号
        }
        let new = Status(accessibilityGranted: accessibilityGranted,
                         screenCaptureGranted: screenCaptureGranted,
                         screenCaptureNeedsReconfirm: needsReconfirm)
        currentStatus = new
        lock.unlock()

        if new != old || !hasNotifiedBaseline {
            hasNotifiedBaseline = true
            onStatusChange?(new)
            statusObservers.forEach { $0(new) }
        }
        return new
    }
}
