import AppKit

// ActionCarrier.swift — 闭包 → target/action 的共用载体（ui-refactor 评审修复：合并菜单、`⋯` 菜单、恢复提示按钮、
// 未就绪重确认状态行各自的同款私有载体）。
// AppKit 的 target 是弱引用：调用方须强持有载体（NSMenuItem 挂 representedObject、视图 / 协调器存属性）。

final class ActionCarrier: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) { self.handler = handler }

    @objc func fire() { handler() }
}
