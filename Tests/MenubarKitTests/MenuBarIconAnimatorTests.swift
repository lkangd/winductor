import XCTest
@testable import MenubarKit

// UI 重构票 02：菜单栏图标三态（ui-refactor spec §4.2）。
// 接缝：MenuBarIconState.derive（纯推导）与 MenuBarIconAnimator（未就绪 / 恢复中两个开关 → 当前帧 + 交替计时器）。
// 计时器经 makeTimer 注入假件：记录间隔、手动触发 tick、记录作废——不跑真实 RunLoop。
final class MenuBarIconAnimatorTests: XCTestCase {
    private final class FakeTimer: MenuBarIconTimer {
        let interval: TimeInterval
        let tick: () -> Void
        private(set) var isInvalidated = false
        init(interval: TimeInterval, tick: @escaping () -> Void) {
            self.interval = interval
            self.tick = tick
        }

        func invalidate() { isInvalidated = true }
    }

    private var timers: [FakeTimer] = []
    private var displayed: [MenuBarIconFrame] = []

    private var liveTimers: [FakeTimer] { timers.filter { !$0.isInvalidated } }

    private func makeAnimator() -> MenuBarIconAnimator {
        MenuBarIconAnimator(makeTimer: { [unowned self] interval, tick in
            let timer = FakeTimer(interval: interval, tick: tick)
            timers.append(timer)
            return timer
        }, display: { [unowned self] frame in displayed.append(frame) })
    }

    // MARK: 态推导

    /// 未就绪优先于恢复中（spec §4.2：接口上同时置位时未就绪优先）
    func testStateDerivation() {
        XCTAssertEqual(MenuBarIconState.derive(notReady: false, restoring: false), .idle)
        XCTAssertEqual(MenuBarIconState.derive(notReady: false, restoring: true), .restoring)
        XCTAssertEqual(MenuBarIconState.derive(notReady: true, restoring: false), .notReady)
        XCTAssertEqual(MenuBarIconState.derive(notReady: true, restoring: true), .notReady)
    }

    /// 交替帧长 0.6s（常量）
    func testRestoringFrameIntervalIsPointSix() {
        XCTAssertEqual(MenuBarIconAnimator.restoringFrameInterval, 0.6)
    }

    // MARK: 交替计时器

    /// 初始：常态图立即上屏，无计时器
    func testStartsIdleWithoutTimer() {
        let animator = makeAnimator()
        XCTAssertEqual(animator.state, .idle)
        XCTAssertEqual(displayed, [.idle])
        XCTAssertTrue(timers.isEmpty)
    }

    /// 恢复开始：立即换恢复中图并起 0.6s 计时器；每跳在恢复中 ↔ 常态间交替
    func testRestoringAlternatesEveryTick() throws {
        let animator = makeAnimator()
        animator.setRestoring(true)
        XCTAssertEqual(animator.state, .restoring)
        XCTAssertEqual(displayed.last, .restoring)
        let timer = try XCTUnwrap(liveTimers.first)
        XCTAssertEqual(liveTimers.count, 1)
        XCTAssertEqual(timer.interval, 0.6)

        timer.tick()
        XCTAssertEqual(animator.frame, .idle)
        timer.tick()
        XCTAssertEqual(animator.frame, .restoring)
        timer.tick()
        XCTAssertEqual(displayed, [.idle, .restoring, .idle, .restoring, .idle])
    }

    /// 恢复结束：立即作废计时器并回常态（停在交替的任一帧都一样）
    func testRestoreEndStopsTimerAndReturnsToIdleImmediately() throws {
        for ticks in 0 ... 1 {
            timers = []
            displayed = []
            let animator = makeAnimator()
            animator.setRestoring(true)
            let timer = try XCTUnwrap(timers.first)
            for _ in 0 ..< ticks { timer.tick() }

            animator.setRestoring(false)
            XCTAssertTrue(timer.isInvalidated, "ticks=\(ticks)")
            XCTAssertEqual(animator.state, .idle)
            XCTAssertEqual(animator.frame, .idle)
            XCTAssertEqual(displayed.last, .idle)

            // 作废后残留的一跳（已入队的回调）不得再换图
            let count = displayed.count
            timer.tick()
            XCTAssertEqual(displayed.count, count, "ticks=\(ticks)")
            XCTAssertEqual(animator.frame, .idle)
        }
    }

    /// 重复置位恢复中不重起计时器、不重复换图
    func testRepeatedRestoringIsIdempotent() {
        let animator = makeAnimator()
        animator.setRestoring(true)
        animator.setRestoring(true)
        XCTAssertEqual(timers.count, 1)
        XCTAssertEqual(displayed, [.idle, .restoring])
        animator.setRestoring(false)
        animator.setRestoring(false)
        XCTAssertEqual(displayed, [.idle, .restoring, .idle])
    }

    // MARK: 未就绪

    /// 未就绪：徽记图，无计时器；恢复就绪回常态
    func testNotReadyShowsBadgeWithoutTimer() {
        let animator = makeAnimator()
        animator.setNotReady(true)
        XCTAssertEqual(animator.state, .notReady)
        XCTAssertEqual(displayed.last, .notReady)
        XCTAssertTrue(timers.isEmpty)
        animator.setNotReady(false)
        XCTAssertEqual(displayed, [.idle, .notReady, .idle])
    }

    /// 恢复中途变未就绪：未就绪优先，交替停；未就绪解除而恢复仍在 → 重新交替；恢复结束 → 常态
    func testNotReadyWinsOverRestoring() throws {
        let animator = makeAnimator()
        animator.setRestoring(true)
        let first = try XCTUnwrap(timers.first)
        animator.setNotReady(true)
        XCTAssertTrue(first.isInvalidated)
        XCTAssertEqual(animator.state, .notReady)
        XCTAssertEqual(displayed.last, .notReady)

        animator.setNotReady(false)
        XCTAssertEqual(animator.state, .restoring)
        XCTAssertEqual(displayed.last, .restoring)
        XCTAssertEqual(liveTimers.count, 1)

        animator.setRestoring(false)
        XCTAssertTrue(liveTimers.isEmpty)
        XCTAssertEqual(displayed.last, .idle)
    }

    /// 未就绪期间置位恢复中：仍是徽记，不起计时器
    func testRestoringWhileNotReadyKeepsBadge() {
        let animator = makeAnimator()
        animator.setNotReady(true)
        animator.setRestoring(true)
        XCTAssertEqual(animator.state, .notReady)
        XCTAssertEqual(displayed, [.idle, .notReady])
        XCTAssertTrue(timers.isEmpty)
    }
}
