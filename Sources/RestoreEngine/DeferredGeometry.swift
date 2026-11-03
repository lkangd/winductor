import AXFacade
import Core
import CoreGraphics
import Foundation

// DeferredGeometry.swift — 后台窗延迟几何（实测缺陷：AX 树只暴露可见 Space 的窗口，
// 恢复时后台窗几何写报 elementInvalid；一次性语义的保留形态 = 每窗延迟单次应用：
// restore 时记录 pending，poller 检测到该窗变为可见时由 Applier 补写一次，之后不再管）。

/// 单条延迟几何：windowID + 目标屏 + 归一比例坐标（快照口径）
public struct PendingGeometryEntry: Codable, Equatable, Sendable {
    public let windowID: UInt32
    public let displayUUID: String
    public let x: Double, y: Double, w: Double, h: Double

    public init(windowID: UInt32, displayUUID: String, x: Double, y: Double, w: Double, h: Double) {
        self.windowID = windowID
        self.displayUUID = displayUUID
        self.x = x; self.y = y; self.w = w; self.h = h
    }
}

/// pending 集合的 JSON 文件存取（restore 结束整写替换 = 上轮 pending 作废，一次性语义）
public final class DeferredGeometryStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(directory: URL, fileName: String = "pending-geometry.json") {
        self.url = directory.appendingPathComponent(fileName)
    }

    public func load() -> [PendingGeometryEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([PendingGeometryEntry].self, from: data) else { return [] }
        return entries
    }

    public func save(_ entries: [PendingGeometryEntry]) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 移除单条并落盘（延迟应用成功/失败后一次性消费）
    public func remove(windowID: UInt32) {
        save(load().filter { $0.windowID != windowID })
    }
}

/// 延迟几何应用器：poller 报告「窗口变为可见」时查 pending 补写一次 AX 几何
/// （此时窗口在可见 Space，AX 可达）。写成功或失败均消费掉（一次性，不重试循环）。
public final class DeferredGeometryApplier: @unchecked Sendable {
    private let store: DeferredGeometryStore
    private let writer: WindowGeometryWriting
    private let displaysProvider: () -> [Displays.Info]
    private let log: LogWriting?

    public init(store: DeferredGeometryStore,
                writer: WindowGeometryWriting = AXGeometryWriter(),
                displaysProvider: @escaping () -> [Displays.Info] = Displays.active,
                log: LogWriting? = nil) {
        self.store = store
        self.writer = writer
        self.displaysProvider = displaysProvider
        self.log = log
    }

    /// 有 pending 则应用一次。返回 true = 存在 pending（无论写成功与否，均已消费）。
    @discardableResult
    public func applyIfPending(windowID: UInt32) -> Bool {
        var entries = store.load()
        guard let idx = entries.firstIndex(where: { $0.windowID == windowID }) else { return false }
        let entry = entries.remove(at: idx)
        defer { store.save(entries) }
        let display = displaysProvider().first { $0.uuid == entry.displayUUID }
            ?? displaysProvider().first
        guard let display, display.bounds.width > 0, display.bounds.height > 0 else {
            log?.write("[restore] deferred wid=\(windowID) result=fail detail=no-active-display")
            return true
        }
        func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
        let position = CGPoint(x: display.bounds.minX + CGFloat(clamp01(entry.x)) * display.bounds.width,
                               y: display.bounds.minY + CGFloat(clamp01(entry.y)) * display.bounds.height)
        let size = CGSize(width: CGFloat(clamp01(entry.w)) * display.bounds.width,
                          height: CGFloat(clamp01(entry.h)) * display.bounds.height)
        do {
            try writer.apply(windowID: windowID, position: position, size: size)
            log?.write("[restore] deferred wid=\(windowID) result=ok detail=background-window-became-visible")
        } catch {
            log?.write("[restore] deferred wid=\(windowID) result=fail detail=\(error)")
        }
        return true
    }
}
