import AppKit
import MenubarKit

// main.swift — 菜单栏 agent 应用入口（票 10 骨架；票 18 权限链路；票 19 全量接线）。
// accessory 激活策略（无 Dock 图标；打包后由 Info.plist LSUIElement 声明，此处为 swift run 裸跑兜底）
// + 装配代理。菜单七项/图标三态/通知/登录启动/Finder 入口/单实例守卫均在 MenubarKit 内组装接线。

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
