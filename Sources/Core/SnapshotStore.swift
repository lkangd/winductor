import Darwin
import Foundation

// SnapshotStore.swift — 快照文件原语：原子写、损坏隔离、应用支持目录。票 11 起步，display-presets 票 02
// 删除 live/history 布局与 UUID 集合拓扑键：预设与回滚快照的落盘布局见 PresetStore.swift，
// 旧 live-*/history-*/undo-* 文件不再读取（不兼容、不迁移）。
// 损坏隔离：原文件名追加 ".corrupt-<ISO8601时间戳>"（时间戳冒号以 "-" 代替，Finder 友好）。

public struct SnapshotStore: Sendable {
    private static let applicationSupportDirectoryName = "Winductor"

    /// 所管目录（隔离日志与相对路径口径用）
    public let directory: URL
    private let log: LogWriting?

    public init(directory: URL, log: LogWriting? = nil) {
        self.directory = directory
        self.log = log
    }

    /// 默认日志目录：~/Library/Application Support/Winductor/logs/
    public static var defaultLogDirectory: URL {
        applicationSupportRoot()
            .appendingPathComponent("logs", isDirectory: true)
    }

    static func applicationSupportRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    // MARK: 写入

    /// 原子写 = 同目录临时文件 + rename(2)（同卷原子替换）：
    /// 写入中途被杀只可能留下临时文件，目标路径要么旧内容完整、要么新内容完整。
    public static func atomicWrite(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }  // rename 成功后此调用无害
        try data.write(to: tmp)
        try rename(tmp, to: url)
    }

    /// rename(2)：POSIX 语义下同卷目标已存在则原子替换；跨设备时回退 remove+move
    private static func rename(_ from: URL, to: URL) throws {
        if Darwin.rename(from.path, to.path) == 0 { return }
        let err = errno
        guard err == EXDEV else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "rename(\(from.lastPathComponent) → \(to.lastPathComponent)) failed"])
        }
        try? FileManager.default.removeItem(at: to)
        try FileManager.default.moveItem(at: from, to: to)
    }

    // MARK: 损坏隔离

    /// 损坏隔离：改名 "<原名>.corrupt-<ISO8601时间戳>"；时间戳冲突追加 -2/-3…
    /// 返回挪去的目标路径（失败返回 nil 并记日志）。
    @discardableResult
    public func quarantine(_ url: URL) -> URL? {
        let stamp = Self.corruptTimestampFormatter.string(from: Date())
        let base = url.lastPathComponent + ".corrupt-" + stamp
        let dir = url.deletingLastPathComponent()
        var target = dir.appendingPathComponent(base)
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            n += 1
            target = dir.appendingPathComponent("\(base)-\(n)")
        }
        do {
            try Self.rename(url, to: target)
            return target
        } catch {
            log?.write("[snapshot] action=quarantine path=\(url.lastPathComponent) result=fail detail=\(error)")
            return nil
        }
    }

    /// 隔离文件名时间戳：ISO8601 但冒号以 "-" 代替（Finder 中 ":" 会显示为 "/"）
    private static let corruptTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ssZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
