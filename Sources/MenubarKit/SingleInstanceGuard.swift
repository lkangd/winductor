import AppKit

// SingleInstanceGuard.swift — 单实例守卫（票 19 修票底编排者缺陷登记，2026-10-30）。
// 缺陷：【立即重启】`open -n` 强拉新实例，旧实例未退净 → 双实例并行轮询/落盘，
// SnapshotStore 轮转 rename ENOENT 竞态。守卫：启动时检测同 bundle id 活实例
// （NSRunningApplication），存在则激活旧实例并退出自身；「先退后拉」重启顺序见 SelfRelauncher。
// undo/恢复管线同样隐含单实例前提（一次性恢复语义）。

public enum SingleInstanceGuard {
    /// 守卫判定结论
    public enum Decision: Equatable {
        /// 无同 bundle id 活实例 → 放行启动
        case proceed
        /// 存在活实例 → 激活旧实例（首项）并退出自身（携带全部旧实例 PID 供日志）
        case activateExistingAndExit([Int32])
    }

    /// 纯判定：runningPIDs 为同 bundle id 全部实例 PID（含自身），排除自身后非空即双实例
    public static func decide(runningPIDs: [Int32], selfPID: Int32) -> Decision {
        let others = runningPIDs.filter { $0 != selfPID }
        guard !others.isEmpty else { return .proceed }
        return .activateExistingAndExit(others)
    }

    /// 启动守卫：返回 true = 放行启动；false = 已激活旧实例且本进程应退出（exitSelf 接缝注入）。
    /// bundleIdentifier 为 nil（裸 swift run 无 bundle）时不设防——无稳定标识可查。
    @discardableResult
    public static func startupGuard(bundleIdentifier: String?,
                                    selfPID: Int32 = ProcessInfo.processInfo.processIdentifier,
                                    runningPIDs: (String) -> [Int32] = Self.runningPIDs(ofBundle:),
                                    activate: (Int32) -> Void = activateFirst,
                                    exitSelf: (Int32) -> Void = { exitCurrentProcess($0) }) -> Bool {
        guard let bundleIdentifier else { return true }
        let decision = decide(runningPIDs: runningPIDs(bundleIdentifier), selfPID: selfPID)
        switch decision {
        case .proceed:
            return true
        case .activateExistingAndExit(let others):
            activate(others.first ?? selfPID)
            exitSelf(selfPID)
            return false  // 不可达（exitSelf 不返回）；测试注入接缝据此断言
        }
    }

    /// 同 bundle id 活实例 PID 列表（生产实现：NSRunningApplication）
    public static func runningPIDs(ofBundle bundleID: String) -> [Int32] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
    }

    /// 激活旧实例（带 Dock/所有空间前台化兜底；accessory agent 无 Dock 也不影响）
    public static func activateFirst(_ pid: Int32) {
        let existing = NSRunningApplication(processIdentifier: pid)
        existing?.activate()
    }

    /// 退出自身（启动尚未装配任何资源，直接 exit 干净利落；不经 terminate 避免触发引擎清理路径）
    public static func exitCurrentProcess(_ pid: Int32) -> Never {
        exit(0)
    }
}
