import AppKit
import MenubarKit

// AppDelegate — 应用装配（票 18）：权限未就绪链路接线。
// 组装：PermissionMonitor（默认真实探针，不主动弹窗）→ 引擎就绪门（未就绪 = 照常轮询零落盘，
// 票 12 语义）+ 状态项警示点/菜单（§8.1/§8.4）+ 首启引导窗决策（§8.3，未就绪先弹、齐备提示重启）。
// 占位菜单保留（全量菜单接线归票 19）。

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 持有整个应用生命周期；stop 停监视器与引擎定时器
    private var coordinator: NotReadyGateCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController()
        controller.showPlaceholderIcon()

        let monitor = PermissionMonitor()
        let coordinator = NotReadyGateCoordinator(
            monitor: monitor,
            statusItem: controller,
            snapshotEngine: RuntimeAssembly.makeSnapshotEngine(gatedBy: monitor)
        )
        coordinator.start()  // 首检决策：notReady→引导窗；ready→直接常态运行
        self.coordinator = coordinator
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}
