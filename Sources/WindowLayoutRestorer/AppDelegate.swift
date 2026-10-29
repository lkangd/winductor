import AppKit
import MenubarKit

// AppDelegate — 应用装配（票 10 骨架）：启动时装状态项与占位菜单。
// 票 18/19 在此扩展：引导窗、图标三态切换、真实菜单动作接线。

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 需持有整个应用生命周期；置 nil 时 deinit 撤下状态项
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController()
        controller.showPlaceholderIcon()
        controller.set(menu: PlaceholderMenu.build())
        statusItem = controller
    }
}
