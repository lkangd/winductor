import AppKit
import MenubarKit

// main.swift — 菜单栏 agent 应用入口（票 10）。
// 骨架：accessory 激活策略（无 Dock 图标；打包后由 Info.plist LSUIElement 声明，
// 此处为 swift run 裸跑时的代码层兜底）+ 状态项占位图标 + 占位菜单。
// 全量接线（图标三态、真实菜单动作、引导窗、通知）在票 19。

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
