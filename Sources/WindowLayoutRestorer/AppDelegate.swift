import AppKit
import MenubarKit

// AppDelegate — 应用装配（票 19 全量接线；票 18 未就绪链路延续）。
// 启动顺序：单实例守卫（票底缺陷：同 bundle id 活实例 → 激活旧实例并退出自身）
// → 状态项（常态网格图）→ 全量恢复栈组装（快照引擎就绪门 + 恢复引擎 + 触发链 + 全量菜单 +
// 通知 + 登录启动 + Finder 入口）→ 未就绪门控启动（首检决策：未就绪弹引导窗/就绪静默）→ 屏幕观察者。
// 退出前停观察者与定时器（applicationWillTerminate）。

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 持有整个应用生命周期；stop 停观察者/引擎定时器/触发链/屏幕观察者
    private var gateCoordinator: NotReadyGateCoordinator?
    private var menuCoordinator: MenuRestoreCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例守卫（票 19 修票底双实例竞态）：放行 false = 已激活旧实例，本进程退出
        guard SingleInstanceGuard.startupGuard(bundleIdentifier: Bundle.main.bundleIdentifier) else { return }

        let controller = StatusItemController()
        controller.showPlaceholderIcon()

        let monitor = PermissionMonitor()
        // app 结构化日志在 assembleAppRoot 缺省落日志目录 app.log（「打开日志文件夹」所指）
        let (gate, menu) = RuntimeAssembly.assembleAppRoot(
            monitor: monitor,
            statusItem: controller,
            notifier: UserNotificationPoster())
        gate.start()        // 票 18：首检决策（未就绪→引导窗；就绪→全量菜单常态运行）+ 引擎启停
        menu.start()        // 票 19：didChangeScreenParameters 观察者 → 触发链 + 菜单刷新

        gateCoordinator = gate
        menuCoordinator = menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuCoordinator?.stop()
        gateCoordinator?.stop()
    }
}
