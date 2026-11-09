import Foundation

// MenuBarIconAnimator.swift — 菜单栏图标三态（UI 重构票 02，ui-refactor spec §4.2）。
// 纯逻辑：未就绪 / 恢复中两个开关 → 图标态（未就绪优先）→ 当前帧；恢复中两图每 0.6s 交替，结束即停并回常态。
// 帧到图像的映射归 MenuBarIconImages，上屏归 StatusItemController（display 闭包）；计时器经 makeTimer 注入可测。
// 仅主线程调用（StatusItemController 负责主线程归一）。

/// 图标态（spec §4.2 三态）
enum MenuBarIconState: Equatable {
    case idle
    case restoring
    case notReady

    /// 未就绪与恢复中不会同时出现（未就绪不触发恢复）；接口上同时置位时未就绪优先
    static func derive(notReady: Bool, restoring: Bool) -> MenuBarIconState {
        if notReady { return .notReady }
        return restoring ? .restoring : .idle
    }
}

/// 上屏的一帧图像：常态图 / 恢复中图 / 常态图 + 镂空「!」徽记
enum MenuBarIconFrame: Equatable {
    case idle
    case restoring
    case notReady
}

/// 交替计时器句柄（生产：Timer；测试：假件）
protocol MenuBarIconTimer: AnyObject {
    func invalidate()
}

extension Timer: MenuBarIconTimer {}

final class MenuBarIconAnimator {
    /// 恢复中交替的每帧时长（spec §4.2：常量，可调）
    static let restoringFrameInterval: TimeInterval = 0.6

    /// 计时器工厂：(间隔, 每跳回调) → 句柄（重复触发，直到 invalidate）
    typealias MakeTimer = (TimeInterval, @escaping () -> Void) -> MenuBarIconTimer

    private(set) var state: MenuBarIconState = .idle
    private(set) var frame: MenuBarIconFrame = .idle

    private var notReady = false
    private var restoring = false
    private var timer: MenuBarIconTimer?
    private let makeTimer: MakeTimer
    private let display: (MenuBarIconFrame) -> Void

    /// 构造即上屏常态图
    init(makeTimer: @escaping MakeTimer = MenuBarIconAnimator.mainRunLoopTimer,
         display: @escaping (MenuBarIconFrame) -> Void) {
        self.makeTimer = makeTimer
        self.display = display
        display(frame)
    }

    deinit {
        timer?.invalidate()
    }

    func setRestoring(_ value: Bool) {
        restoring = value
        apply()
    }

    func setNotReady(_ value: Bool) {
        notReady = value
        apply()
    }

    /// 态变化才动作：进恢复中 → 立即换恢复中图并起计时器；离开 → 立即作废计时器并换该态的静态图
    private func apply() {
        let next = MenuBarIconState.derive(notReady: notReady, restoring: restoring)
        guard next != state else { return }
        state = next
        timer?.invalidate()
        timer = nil
        switch next {
        case .idle:
            show(.idle)
        case .notReady:
            show(.notReady)
        case .restoring:
            show(.restoring)
            timer = makeTimer(Self.restoringFrameInterval) { [weak self] in self?.tick() }
        }
    }

    private func tick() {
        // 作废后残留的一跳（已入队回调）不换图
        guard state == .restoring else { return }
        show(frame == .restoring ? .idle : .restoring)
    }

    private func show(_ next: MenuBarIconFrame) {
        guard next != frame else { return }
        frame = next
        display(next)
    }

    /// 生产计时器：主 RunLoop .common 模式（菜单展开的事件跟踪期间也要继续交替）
    static func mainRunLoopTimer(interval: TimeInterval, tick: @escaping () -> Void) -> MenuBarIconTimer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in tick() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
