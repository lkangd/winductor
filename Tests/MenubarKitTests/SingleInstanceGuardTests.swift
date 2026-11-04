import XCTest
@testable import MenubarKit

// 票 19：单实例守卫（票底编排者缺陷登记：`open -n` 双实例竞态 → SnapshotStore 轮转 rename
// ENOENT）+【立即重启】先退后拉顺序。接缝：
//   SingleInstanceGuard.decide(runningPIDs:selfPID:) 纯判定（.proceed / .activateExistingAndExit）；
//   SelfRelauncher 的重启监视进程命令构造（旧 PID 消失后才 open 新实例）与执行顺序。
final class SingleInstanceGuardTests: XCTestCase {
    // MARK: 守卫判定（启动时检测同 bundle id 活实例）

    /// 无其他实例 → 放行启动
    func testNoOtherInstanceProceeds() {
        XCTAssertEqual(SingleInstanceGuard.decide(runningPIDs: [400], selfPID: 400), .proceed)
        XCTAssertEqual(SingleInstanceGuard.decide(runningPIDs: [], selfPID: 400), .proceed)
    }

    /// 存在其他实例 → 激活旧实例并退出自身（不能双实例并行轮询/落盘）
    func testOtherInstanceActivatesAndExits() {
        XCTAssertEqual(SingleInstanceGuard.decide(runningPIDs: [400, 501], selfPID: 400),
                       .activateExistingAndExit([501]))
        // 多个旧实例（异常残留）：全部上报，激活第一个、退出自身
        XCTAssertEqual(SingleInstanceGuard.decide(runningPIDs: [400, 501, 502], selfPID: 400),
                       .activateExistingAndExit([501, 502]))
    }

    /// 真实入口：按 bundle id 查 NSRunningApplication、排除自身 PID
    func testStartupGuardUsesRunningApplicationsExcludingSelf() throws {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        // 自己的 bundle id 不该有「其他」实例 → 放行
        XCTAssertTrue(SingleInstanceGuard.startupGuard(bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.lkd.window-restore",
                                                       selfPID: selfPID,
                                                       runningPIDs: { _ in [selfPID] },
                                                       activate: { _ in XCTFail("放行路径不得激活") },
                                                       exitSelf: { _ in XCTFail("放行路径不得退出") }))
        // 有其他实例 → 激活之 + 退出自身（exit 由注入接缝捕获，不真退测试进程）
        var activated: [Int32] = []
        var exited = false
        XCTAssertFalse(SingleInstanceGuard.startupGuard(bundleIdentifier: "com.lkd.window-restore",
                                                        selfPID: selfPID,
                                                        runningPIDs: { _ in [selfPID, 999999] },
                                                        activate: { activated.append($0) },
                                                        exitSelf: { _ in exited = true }))
        XCTAssertEqual(activated, [999999])
        XCTAssertTrue(exited)
    }

    // MARK:【立即重启】先退后拉（票底缺陷修复：旧实例退净才拉新实例）

    /// 重启监视进程：等待旧 PID 退出后才 open（/bin/sh -c 'while kill -0 …; open -n …'）
    func testRestartWatcherWaitsForOldPIDDeathBeforeOpen() {
        let args = SelfRelauncher.restartWatcherArguments(pid: 4242,
                                                          bundlePath: "/Applications/Winductor.app")
        let script = args.joined(separator: " ")
        XCTAssertTrue(script.contains("kill -0 4242"), "必须轮询旧实例 PID")
        XCTAssertTrue(script.contains("open -n"), "必须强制新实例拉起（不带 -n 会被解析为激活旧实例）")
        XCTAssertTrue(script.contains("/Applications/Winductor.app"))
    }

    /// 执行顺序：先落重启监视进程（存活于本进程之外），后干净退出自身
    func testPerformSpawnsWatcherThenTerminates() throws {
        var order: [String] = []
        SelfRelauncher.perform(
            spawnWatcher: { _, _ in order.append("spawn") },
            terminate: { order.append("terminate") })
        XCTAssertEqual(order, ["spawn", "terminate"], "先退后拉：监视进程必须先于退出存在")
    }

    /// 拉起失败（spawn 抛错）→ 留在当前实例不自杀（票 18 语义延续）
    func testPerformKeepsInstanceWhenSpawnFails() {
        var terminated = false
        struct SpawnError: Error {}
        SelfRelauncher.perform(
            spawnWatcher: { _, _ in throw SpawnError() },
            terminate: { terminated = true })
        XCTAssertFalse(terminated, "监视进程落空必须留在当前实例")
    }
}
