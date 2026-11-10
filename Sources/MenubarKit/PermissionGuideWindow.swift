import AppKit
import SwiftUI

// PermissionGuideWindow.swift — 首启授权窗（票 18 起；ui-refactor 票 05 按 spec §6 重写为 SwiftUI，NSHostingView 宿主）。
// 独立窗口、浮层前置、首启硬前置；宽 580，透明标题栏。每 2s 由 PermissionMonitor 状态推进（update(status:)），
// 逐项显示已授权/未授权，本次运行中两项齐备后底部条换重启提示 +【立即重启】；启动即就绪后按需打开则只显示齐备、无需重启。
// 窗口不随权限就绪自动关闭——重启提示是用户需要看到的终态。
// 排版见 PermissionGuideView，状态推导见 PermissionGuideState；本类只做宿主与观察接缝。

public final class PermissionGuideWindow {
    /// 授权窗本体（独立窗口，非状态项菜单）
    public let window: NSWindow
    private let model: PermissionGuideModel
    /// 系统设置面板名（随 macOS 版本；票 09）
    private let paneNames: SystemSettingsPaneNames

    public init(paneNames: SystemSettingsPaneNames = .current,
                openSettings: @escaping (PermissionMonitor.Kind) -> Void = SystemSettingsOpener.open,
                relaunch: @escaping () -> Void = { SelfRelauncher.perform() }) {
        // 初始 = 两项未授权（首个 update 前的占位；协调器建窗后立即推进到真实现状）
        let initial = PermissionMonitor.Status(accessibilityGranted: false, screenCaptureGranted: false,
                                               screenCaptureNeedsReconfirm: false)
        self.paneNames = paneNames
        model = PermissionGuideModel(state: PermissionGuideState(status: initial, hasBeenNotReady: true,
                                                                 paneNames: paneNames),
                                     openSettings: openSettings, relaunch: relaunch)

        let host = NSHostingView(rootView: PermissionGuideView(model: model))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                          styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = model.state.title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = host  // 高度随内容（路径行增减）由宿主固有尺寸驱动
        window.center()
    }

    // MARK: 呈现观察接缝（测试与装配方复用）

    /// 当前呈现状态
    public var state: PermissionGuideState { model.state }
    /// 当前可见的全部文本（页头、各行、底部条；按钮标题除外）
    public var visibleTexts: [String] { model.state.visibleTexts }
    /// 底部状态条文本（齐备：标题 + 说明；未齐备：等待提示）
    public var statusTexts: [String] { model.state.footerTexts }
    /// 当前可见的【打开系统设置】按钮（按行序）
    public var visibleSettingsButtons: [PermissionMonitor.Kind] {
        model.state.rows.filter(\.showsOpenSettingsButton).map(\.kind)
    }

    public var settingsButtonTitle: String { PermissionGuideState.Row.openSettingsButtonTitle }
    /// 【立即重启】是否可见（未齐备隐藏）
    public var isRestartButtonVisible: Bool { model.state.footer.showsRestartButton }
    public var restartButtonTitle: String { model.state.footer.restartButtonTitle }

    /// 点击某行【打开系统设置】（视图按钮同一入口；该行已授权、按钮不可见时不响应）
    public func pressOpenSettings(_ kind: PermissionMonitor.Kind) { model.pressOpenSettings(kind) }
    /// 点击【立即重启】（视图按钮同一入口；未齐备、按钮不可见时不响应）
    public func pressRestart() { model.pressRestart() }

    // MARK: 状态推进（PermissionMonitor 每 2s 回调驱动）

    /// 依据权限现状推进界面：逐项已授权/未授权，底部条等待 ⇄ 齐备（本次运行中出现过未就绪 → 重启提示，否则无需重启；§6）。不关窗
    public func update(status: PermissionMonitor.Status, hasBeenNotReady: Bool) {
        let next = PermissionGuideState(status: status, hasBeenNotReady: hasBeenNotReady, paneNames: paneNames)
        guard next != model.state else { return }
        model.state = next
    }

    /// 呈现授权窗：浮层前置（accessory 应用无 Dock 图标，需显式激活）
    public func show() {
        window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
