import Foundation
import ServiceManagement

// LoginItemService.swift — 登录时启动（票 19，spec §8.2/09 三：唯一设置项）。
// 生产实现：SMAppService.mainApp（macOS 13+；非沙盒直接可用，票面已注明）。
// 勾选态 = status == .enabled；切换 = register/unregister，失败抛错由协调器记日志并保持现状。

public final class SMAppServiceLoginItem: LoginItemServicing {
    public init() {}

    /// 菜单勾选态（requiresApproval/notRegistered 等一律视为未勾选）
    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    public func enable() throws {
        try SMAppService.mainApp.register()
    }

    public func disable() throws {
        try SMAppService.mainApp.unregister()
    }
}
