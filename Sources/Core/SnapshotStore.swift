import Darwin
import Foundation

// SnapshotStore.swift — 快照存储原语（spec §7.4）。票 11 拥有本文件。
// 目录布局（文件名格式冻结，后续票 12 落盘 / 票 16 回滚快照沿用，勿改）：
//   <snapshots>/live-<拓扑键>.json               现势快照（每拓扑 1 份）
//   <snapshots>/history-<slot>-<拓扑键>.json     滚动历史（slot 1..historySlots，1 = 最新）
//   <snapshots>/undo-<拓扑键>.json               回滚快照（票 16 使用；本票仅冻结文件名）
// 拓扑键 = 该拓扑全部显示器稳定 UUID 字典序排序后以 "-" 连接
//   （CFUUID 形如 XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX，36 字符含 "-"，段长恒定可无歧义拆分；
//    排序保证与枚举顺序无关）。例：live-0A938E2D-…-37D8832A-….json
// 损坏隔离：原文件名追加 ".corrupt-<ISO8601时间戳>"（时间戳冒号以 "-" 代替，Finder 友好）。

public struct SnapshotStore: Sendable {
    private static let applicationSupportDirectoryName = "Winductor"
    // 首次启动新版本时迁移旧产品目录中的快照、待处理几何和日志。
    private static let legacyApplicationSupportDirectoryName = "WindowLayoutRestorer"
    private static let applicationSupportMigrationLock = NSLock()

    /// 快照根目录（spec §7.4）
    public let directory: URL
    /// 滚动历史份数（spec §7.4：现势 1 + 历史 4）
    public let historySlots: Int
    private let log: LogWriting?

    public init(directory: URL, historySlots: Int = 4, log: LogWriting? = nil) {
        self.directory = directory
        self.historySlots = historySlots
        self.log = log
    }

    /// 默认目录：~/Library/Application Support/Winductor/snapshots/
    public static var defaultDirectory: URL {
        applicationSupportRoot()
            .appendingPathComponent("snapshots", isDirectory: true)
    }

    /// 默认日志目录：~/Library/Application Support/Winductor/logs/
    public static var defaultLogDirectory: URL {
        applicationSupportRoot()
            .appendingPathComponent("logs", isDirectory: true)
    }

    /// 将旧目录中尚未迁移的内容移入新目录；同名文件保留新版文件，不覆盖用户当前数据。
    private static func applicationSupportRoot() -> URL {
        let supportBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = supportBase.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
        let legacy = supportBase.appendingPathComponent(legacyApplicationSupportDirectoryName, isDirectory: true)

        applicationSupportMigrationLock.lock()
        defer { applicationSupportMigrationLock.unlock() }
        do {
            try moveMissingItems(from: legacy, to: current)
        } catch {
            // 如果系统阻止迁移且新目录尚不存在，继续使用旧目录以保留现有快照。
            if !FileManager.default.fileExists(atPath: current.path) { return legacy }
        }
        return current
    }

    private static func moveMissingItems(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        var sourceIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory) else { return }

        var destinationIsDirectory: ObjCBool = false
        let destinationExists = fileManager.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory)
        if !destinationExists {
            try fileManager.moveItem(at: source, to: destination)
            return
        }
        guard sourceIsDirectory.boolValue, destinationIsDirectory.boolValue else { return }

        let children = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for child in children {
            try moveMissingItems(from: child, to: destination.appendingPathComponent(child.lastPathComponent))
        }
        if try fileManager.contentsOfDirectory(atPath: source.path).isEmpty {
            try fileManager.removeItem(at: source)
        }
    }

    // MARK: 拓扑键与路径

    /// 拓扑键 = 排序显示器 UUID 集合以 "-" 连接（格式见文件头注释，后续票沿用）
    public static func topologyKey(forDisplayUUIDs uuids: [String]) -> String {
        uuids.sorted().joined(separator: "-")
    }

    /// 拓扑键反拆 UUID 集合：键 = 36 字符 UUID 段（段内含连字符）以 "-" 连接，段长恒定可无歧义反拆；
    /// 非该格式返回 nil
    public static func displayUUIDs(inTopologyKey key: String) -> [String]? {
        let segments = (key.count + 1) / 37
        guard segments >= 1, key.count == segments * 37 - 1 else { return nil }
        var uuids: [String] = []
        var index = key.startIndex
        for i in 0..<segments {
            if i > 0 {
                guard key[index] == "-" else { return nil }
                index = key.index(after: index)
            }
            guard let end = key.index(index, offsetBy: 36, limitedBy: key.endIndex) else {
                return nil
            }
            uuids.append(String(key[index..<end]))
            index = end
        }
        return uuids
    }

    public func liveURL(topologyKey: String) -> URL {
        directory.appendingPathComponent("live-\(topologyKey).json")
    }

    public func historyURL(topologyKey: String, slot: Int) -> URL {
        directory.appendingPathComponent("history-\(slot)-\(topologyKey).json")
    }

    /// 回滚快照路径（spec §7.4；票 16 使用，文件名格式本票冻结）
    public func undoURL(topologyKey: String) -> URL {
        directory.appendingPathComponent("undo-\(topologyKey).json")
    }

    // MARK: 写入

    /// 落盘：滚动历史（现势 → history-1 → … → history-4，最旧丢弃）后原子写新现势。
    /// 历史滚动失败只记日志、不阻断现势写入。
    public func write(_ snapshot: Snapshot, topologyKey: String) throws {
        let fm = FileManager.default
        // 先滚动历史（从最旧端起 rename 覆盖，rename(2) 同目录原子替换）
        if historySlots >= 1 {
            for slot in stride(from: historySlots, through: 2, by: -1) {
                let src = historyURL(topologyKey: topologyKey, slot: slot - 1)
                let dst = historyURL(topologyKey: topologyKey, slot: slot)
                guard fm.fileExists(atPath: src.path) else { continue }
                do { try Self.rename(src, to: dst) }
                catch { self.log?.write("[snapshot] action=rotate path=\(src.lastPathComponent) result=fail detail=\(error)") }
            }
            do { try Self.rename(liveURL(topologyKey: topologyKey),
                                 to: historyURL(topologyKey: topologyKey, slot: 1)) }
            catch let e as NSError where e.code != CocoaError.fileNoSuchFile.rawValue {
                self.log?.write("[snapshot] action=rotate path=live-\(topologyKey).json result=fail detail=\(e)")
            }
            catch { /* live 不存在属首次落盘，无需日志 */ }
        }
        let data = try snapshot.encoded()
        try Self.atomicWrite(data, to: liveURL(topologyKey: topologyKey))
        log?.write("[snapshot] action=write path=live-\(topologyKey).json result=ok detail=windows=\(snapshot.windows.count)")
    }

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

    // MARK: 读取

    /// 加载现势快照；解析失败 → 隔离 + 沿 history-1..N 回退；版本拒用 → 不隔离继续回退。
    /// 全部不可用返回 nil（含目录不存在）。候选新鲜度顺序：live, history-1..N。
    public func loadLive(topologyKey: String) -> Snapshot? {
        var candidates = [liveURL(topologyKey: topologyKey)]
        if historySlots >= 1 {
            candidates += (1...historySlots).map { historyURL(topologyKey: topologyKey, slot: $0) }
        }
        for url in candidates {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let data = try Data(contentsOf: url)
                let snapshot = try Snapshot.decode(from: data)
                log?.write("[snapshot] action=load path=\(url.lastPathComponent) result=ok detail=windows=\(snapshot.windows.count)")
                return snapshot
            } catch let error as SnapshotSchemaError {
                // 版本拒用（spec §7.3）：文件本身合法 JSON，原位保留、不迁移，继续找历史
                switch error {
                case .unsupportedVersion(let found, let supported):
                    log?.write("[snapshot] action=load path=\(url.lastPathComponent) result=fail "
                        + "detail=unsupported-version found=\(found) supported=\(supported) 拒用不迁移")
                case .invalidVersion(let found):
                    log?.write("[snapshot] action=load path=\(url.lastPathComponent) result=fail "
                        + "detail=invalid-version found=\(found)")
                }
                continue
            } catch CocoaError.fileReadNoSuchFile {
                continue  // 竞争中被删，静默跳过
            } catch {
                // 解析失败 = 损坏：改名挪开 + 记日志，继续回退
                let moved = quarantine(url)
                log?.write("[snapshot] action=quarantine path=\(url.lastPathComponent) result=ok "
                    + "detail=corrupt → \(moved?.lastPathComponent ?? "隔离失败")")
                continue
            }
        }
        log?.write("[snapshot] action=load path=live-\(topologyKey).json result=fail detail=no-valid-snapshot")
        return nil
    }

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
