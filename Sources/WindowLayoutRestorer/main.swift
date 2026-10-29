import AppKit

// main.swift — 菜单栏 agent 应用入口（票 10 拥有本文件）。
// 占位骨架：保证 swift run 可启动。票 10 换成 NSStatusItem + 占位菜单。

let app = NSApplication.shared
// LSUIElement 的代码层兜底（Info.plist 亦声明）：无 Dock 图标的菜单栏 agent
app.setActivationPolicy(.accessory)
app.run()
