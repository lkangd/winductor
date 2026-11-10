import AppKit
import Darwin
import MenubarKit

// main.swift — 菜单栏 agent 应用入口（票 10 骨架；票 18 权限链路；票 19 全量接线）。
// accessory 激活策略（无 Dock 图标；打包后由 Info.plist LSUIElement 声明，此处为 swift run 裸跑兜底）
// + 装配代理。菜单七项/图标三态/通知/登录启动/Finder 入口/单实例守卫均在 MenubarKit 内组装接线。

// 临时通知诊断已撤除；旧交接里的诊断参数应安全退出，不能误启动正常恢复栈。
if CommandLine.arguments.contains("--test-notification") || CommandLine.arguments.contains("--request-notification-permission") {
    fputs("临时通知诊断已撤除；未启动应用或恢复引擎。\n", stderr)
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
