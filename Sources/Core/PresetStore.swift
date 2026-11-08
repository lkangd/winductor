import Foundation

// PresetStore.swift — 预设存储（spec §3.2/§4.1/§4.2/§4.4）。取代 SnapshotStore 的 live/history 布局，旧文件不读取。
// 目录布局（每拓扑一个目录，目录名 = 拓扑键，见 TopologyIdentity）：
//   <presets>/<拓扑键>/topology.json        拓扑元数据：规范化描述 + 展示数据 + 别名 + 自动预设 id + 最近恢复预设 id
//   <presets>/<拓扑键>/preset-<id>.json     单个预设：id、名称、保存时间、快照（每预设一文件，损坏只殃及自身）
//   <presets>/<拓扑键>/undo.json            回滚快照（每拓扑一份，恢复引擎读写）
// 自动标记只存在 topology.json 的 autoPresetID 一处：「至多一个自动」由结构保证，设/取消自动只写一个文件。
// 写入一律原子（SnapshotStore.atomicWrite）；解析失败 = 损坏 → 隔离改名（SnapshotStore.quarantine 口径）后跳过；
// 版本拒用不隔离、原位保留跳过。读-改-写在写锁内：进程内 NSLock + 根目录 .write.lock 的 flock（跨进程）。

public let presetSchemaVersion = 1

/// 预设（spec §4.1）
public struct Preset: Equatable, Sendable {
    public let id: String
    public var name: String
    public var savedAt: Date
    public var isAuto: Bool
    public var snapshot: Snapshot
}

/// 一个拓扑下的全部存储内容
public struct PresetTopology: Equatable, Sendable {
    public let key: String
    /// 规范化描述（TopologyIdentity.canonicalDescription，人读用；元数据损坏时为空）
    public var canonicalDescription: String
    /// 展示数据（spec §3.2，随保存/覆盖预设刷新）
    public var displays: [TopologyDisplayInfo]
    /// 用户别名（nil = 默认显示屏幕名组合）
    public var alias: String?
    /// 预设，按保存时间升序（同秒按名称）
    public var presets: [Preset]
    /// 最近一次恢复所用预设 id（spec §4.4；该预设已删/不可读时为 nil）
    public var lastRestoredPresetID: String?

    public var autoPreset: Preset? { presets.first(where: \.isAuto) }
}

public enum PresetStoreError: Error, Equatable {
    /// 拓扑或预设不存在
    case presetNotFound(topologyKey: String, presetID: String)
    /// 同拓扑内已有同名预设（spec §4.1：撞名提示改名）
    case duplicateName(String)
    /// 名称去首尾空白后为空
    case emptyName
    /// 拓扑不存在（既无元数据也无预设）
    case topologyNotFound(String)
    /// 镜像中禁止保存（spec §3.3）
    case mirrored
}

public struct PresetStore: Sendable {
    /// 预设根目录
    public let directory: URL
    private let files: SnapshotStore
    private let log: LogWriting?
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> String
    /// 进程内写串行（读-改-写多文件；菜单/管理窗口与恢复管线线程可能并发写同一拓扑元数据）；
    /// 跨进程（app 与 DebugCLI 同写一个目录）另由 writeLockURL 上的 flock 串行，见 acquireWriteLock
    private static let processWriteLock = NSLock()

    public init(directory: URL, log: LogWriting? = nil,
                now: @escaping @Sendable () -> Date = Date.init,
                makeID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.directory = directory
        self.files = SnapshotStore(directory: directory, log: log)
        self.log = log
        self.now = now
        self.makeID = makeID
    }

    /// 默认目录：~/Library/Application Support/Winductor/presets/
    public static var defaultDirectory: URL {
        SnapshotStore.applicationSupportRoot().appendingPathComponent("presets", isDirectory: true)
    }

    // MARK: 读取

    /// 列出全部拓扑（含无预设但有元数据者；只有回滚快照的目录不列）
    public func topologies() -> [PresetTopology] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
            .compactMap(topology(key:))
    }

    /// 读一个拓扑；目录不存在或既无元数据又无预设返回 nil
    public func topology(key: String) -> PresetTopology? {
        let meta = loadMeta(key: key)
        let records = loadPresetFiles(key: key)
        guard meta != nil || !records.isEmpty else { return nil }
        let presets = records
            .map { Preset(id: $0.id, name: $0.name, savedAt: $0.savedAt,
                          isAuto: $0.id == meta?.autoPresetID, snapshot: $0.snapshot) }
            .sorted { ($0.savedAt, $0.name) < ($1.savedAt, $1.name) }
        return PresetTopology(
            key: key,
            canonicalDescription: meta?.canonicalDescription ?? "",
            displays: meta?.displays ?? [],
            alias: meta?.alias,
            presets: presets,
            lastRestoredPresetID: presets.contains { $0.id == meta?.lastRestoredPresetID }
                ? meta?.lastRestoredPresetID : nil)
    }

    // MARK: 写入

    /// 新增预设到观测拓扑；拓扑下无任何预设时默认自动（spec §4.2）。同时刷新展示数据。
    /// 名称去首尾空白；同拓扑撞名抛 duplicateName。
    @discardableResult
    public func addPreset(name: String, snapshot: Snapshot, topology: ObservedTopology) throws -> Preset {
        let held = try acquireWriteLock(); defer { held.release() }
        guard !topology.isMirrored else { throw PresetStoreError.mirrored }
        let key = topology.identity.key
        let existing = loadPresetFiles(key: key)
        let name = try validatedName(name, among: existing, excluding: nil)
        let record = PresetFile(version: presetSchemaVersion, id: makeID(), name: name,
                                savedAt: now(), snapshot: snapshot)
        try writePresetFile(record, key: key)
        var meta = loadMeta(key: key) ?? TopologyMeta(key: key)
        meta.refresh(from: topology)
        let isAuto = existing.isEmpty
        if isAuto { meta.autoPresetID = record.id }
        try writeMeta(meta)
        log?.write("[preset] action=add topology=\(key) preset=\(record.id) result=ok detail=auto=\(isAuto)")
        return Preset(id: record.id, name: name, savedAt: record.savedAt, isAuto: isAuto, snapshot: snapshot)
    }

    /// 用当前布局覆盖预设（spec §4.2）：保留名称与自动标记，更新快照与保存时间；展示数据随之刷新。
    /// 只能覆盖观测拓扑下的预设（调用方保证「仅当前拓扑」）。
    @discardableResult
    public func overwritePreset(id: String, snapshot: Snapshot, topology: ObservedTopology) throws -> Preset {
        let held = try acquireWriteLock(); defer { held.release() }
        guard !topology.isMirrored else { throw PresetStoreError.mirrored }
        let key = topology.identity.key
        var meta = try metaForExistingPreset(id, key: key)
        guard var record = loadPresetFiles(key: key).first(where: { $0.id == id }) else {
            throw PresetStoreError.presetNotFound(topologyKey: key, presetID: id)
        }
        record.snapshot = snapshot
        record.savedAt = now()
        try writePresetFile(record, key: key)
        meta.refresh(from: topology)
        try writeMeta(meta)
        log?.write("[preset] action=overwrite topology=\(key) preset=\(id) result=ok")
        return Preset(id: id, name: record.name, savedAt: record.savedAt,
                      isAuto: meta.autoPresetID == id, snapshot: snapshot)
    }

    /// 改名（spec §4.1）：同拓扑唯一；改成自己现有名字为空操作
    public func renamePreset(id: String, topologyKey key: String, to newName: String) throws {
        let held = try acquireWriteLock(); defer { held.release() }
        let records = loadPresetFiles(key: key)
        guard var record = records.first(where: { $0.id == id }) else {
            throw PresetStoreError.presetNotFound(topologyKey: key, presetID: id)
        }
        record.name = try validatedName(newName, among: records, excluding: id)
        try writePresetFile(record, key: key)
        log?.write("[preset] action=rename topology=\(key) preset=\(id) result=ok")
    }

    /// 设/取消自动（spec §4.2）：设为自动 = 同拓扑其他预设自动清除；取消非自动预设为空操作
    public func setAuto(_ isAuto: Bool, presetID: String, topologyKey key: String) throws {
        let held = try acquireWriteLock(); defer { held.release() }
        var meta = try metaForExistingPreset(presetID, key: key)
        if isAuto {
            meta.autoPresetID = presetID
        } else if meta.autoPresetID == presetID {
            meta.autoPresetID = nil
        }
        try writeMeta(meta)
        log?.write("[preset] action=set-auto topology=\(key) preset=\(presetID) result=ok detail=auto=\(isAuto)")
    }

    /// 删除预设（spec §4.2）：删的是自动预设则拓扑变为「无自动」，不转移；最近恢复记录同步清除。
    /// 拓扑目录与元数据（别名等）保留。
    public func deletePreset(id: String, topologyKey key: String) throws {
        let held = try acquireWriteLock(); defer { held.release() }
        var meta = try metaForExistingPreset(id, key: key)
        try FileManager.default.removeItem(at: presetURL(key, id: id))
        if meta.autoPresetID == id || meta.lastRestoredPresetID == id {
            if meta.autoPresetID == id { meta.autoPresetID = nil }
            if meta.lastRestoredPresetID == id { meta.lastRestoredPresetID = nil }
            try writeMeta(meta)
        }
        log?.write("[preset] action=delete topology=\(key) preset=\(id) result=ok")
    }

    /// 改别名（spec §3.2）：去首尾空白，空 = 清除（回到默认屏名组合）
    public func setAlias(_ alias: String?, topologyKey key: String) throws {
        let held = try acquireWriteLock(); defer { held.release() }
        guard topology(key: key) != nil else { throw PresetStoreError.topologyNotFound(key) }
        var meta = loadMeta(key: key) ?? TopologyMeta(key: key)
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        meta.alias = trimmed.isEmpty ? nil : trimmed
        try writeMeta(meta)
        log?.write("[preset] action=alias topology=\(key) result=ok")
    }

    /// 记录最近一次恢复所用预设（spec §4.4，验证器默认基准）
    public func recordRestored(presetID: String, topologyKey key: String) throws {
        let held = try acquireWriteLock(); defer { held.release() }
        var meta = try metaForExistingPreset(presetID, key: key)
        meta.lastRestoredPresetID = presetID
        try writeMeta(meta)
        log?.write("[preset] action=record-restored topology=\(key) preset=\(presetID) result=ok")
    }

    // MARK: 写锁

    /// 跨进程写锁文件（存储根目录下；文件不是目录，不会被当作拓扑列出）。
    /// 所有写入方（app、DebugCLI）对它 flock(LOCK_EX) 后才做读-改-写
    public var writeLockURL: URL {
        directory.appendingPathComponent(".write.lock")
    }

    /// 持有中的写锁（release 依次放 flock 与进程内锁）
    private struct WriteLockHold {
        let fd: Int32

        func release() {
            flock(fd, LOCK_UN)
            close(fd)
            PresetStore.processWriteLock.unlock()
        }
    }

    /// 取写锁：先进程内 NSLock（同进程多线程不必各开 fd 排队），再对锁文件 flock 阻塞等待（跨进程）
    private func acquireWriteLock() throws -> WriteLockHold {
        Self.processWriteLock.lock()
        func fail(_ what: String, _ code: Int32) -> Error {
            Self.processWriteLock.unlock()
            return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                           userInfo: [NSLocalizedDescriptionKey: "\(what) \(writeLockURL.lastPathComponent) failed"])
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Self.processWriteLock.unlock()
            throw error
        }
        let fd = open(writeLockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw fail("open", errno) }
        while flock(fd, LOCK_EX) != 0 {
            let code = errno
            guard code == EINTR else {
                close(fd)
                throw fail("flock", code)
            }
        }
        return WriteLockHold(fd: fd)
    }

    /// 去首尾空白 + 同拓扑唯一（excluding = 改名时自身 id）
    private func validatedName(_ raw: String, among records: [PresetFile], excluding id: String?) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PresetStoreError.emptyName }
        guard !records.contains(where: { $0.name == name && $0.id != id }) else {
            throw PresetStoreError.duplicateName(name)
        }
        return name
    }

    /// 预设须存在；返回其拓扑元数据（元数据缺失/损坏时以空元数据起步）
    private func metaForExistingPreset(_ presetID: String, key: String) throws -> TopologyMeta {
        guard loadPresetFiles(key: key).contains(where: { $0.id == presetID }) else {
            throw PresetStoreError.presetNotFound(topologyKey: key, presetID: presetID)
        }
        return loadMeta(key: key) ?? TopologyMeta(key: key)
    }

    // MARK: 回滚快照

    /// 回滚快照路径（每拓扑一份，恢复引擎恢复前写、撤销读）
    public func undoURL(topologyKey key: String) -> URL {
        topologyDirectory(key).appendingPathComponent("undo.json")
    }

    /// 损坏隔离（SnapshotStore.quarantine 口径：改名 "<原名>.corrupt-<时间戳>"）
    @discardableResult
    public func quarantine(_ url: URL) -> URL? {
        files.quarantine(url)
    }

    // MARK: 路径

    private func topologyDirectory(_ key: String) -> URL {
        directory.appendingPathComponent(key, isDirectory: true)
    }

    private func metaURL(_ key: String) -> URL {
        topologyDirectory(key).appendingPathComponent("topology.json")
    }

    private func presetURL(_ key: String, id: String) -> URL {
        topologyDirectory(key).appendingPathComponent("preset-\(id).json")
    }

    // MARK: 文件编解码

    private func loadMeta(key: String) -> TopologyMeta? {
        decodeFile(metaURL(key), as: TopologyMeta.self)
    }

    private func loadPresetFiles(key: String) -> [PresetFile] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: topologyDirectory(key).path) else {
            return []
        }
        return names
            .filter { $0.hasPrefix("preset-") && $0.hasSuffix(".json") }
            .sorted()
            .compactMap { decodeFile(topologyDirectory(key).appendingPathComponent($0), as: PresetFile.self) }
    }

    private func writeMeta(_ meta: TopologyMeta) throws {
        try SnapshotStore.atomicWrite(try Self.encode(meta), to: metaURL(meta.key))
    }

    private func writePresetFile(_ record: PresetFile, key: String) throws {
        try SnapshotStore.atomicWrite(try Self.encode(record), to: presetURL(key, id: record.id))
    }

    /// 读 + 版本守卫：缺失 → nil；版本拒用（文件或内嵌快照）→ 原位保留 nil；解析失败 → 隔离 nil
    private func decodeFile<T: VersionedFile>(_ url: URL, as type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let found = try decoder.decode(VersionPeek.self, from: data).version
            guard found == presetSchemaVersion else {
                log?.write("[preset] action=load path=\(url.lastPathComponent) result=fail "
                    + "detail=unsupported-version found=\(found) supported=\(presetSchemaVersion) 拒用不迁移")
                return nil
            }
            let value = try decoder.decode(T.self, from: data)
            if let snapshotVersion = value.embeddedSnapshotVersion, snapshotVersion != snapshotSchemaVersion {
                log?.write("[preset] action=load path=\(url.lastPathComponent) result=fail "
                    + "detail=unsupported-snapshot-version found=\(snapshotVersion) supported=\(snapshotSchemaVersion) 拒用不迁移")
                return nil
            }
            return value
        } catch {
            let moved = files.quarantine(url)
            log?.write("[preset] action=quarantine path=\(url.lastPathComponent) result=ok "
                + "detail=corrupt → \(moved?.lastPathComponent ?? "隔离失败")")
            return nil
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
}

// MARK: - 落盘形态

private struct VersionPeek: Decodable { let version: Int }

private protocol VersionedFile: Codable {
    /// 内嵌快照的 schema 版本（无内嵌快照为 nil）
    var embeddedSnapshotVersion: Int? { get }
}

/// topology.json
private struct TopologyMeta: VersionedFile {
    var version = presetSchemaVersion
    var key: String
    var canonicalDescription = ""
    var displays: [TopologyDisplayInfo] = []
    var alias: String?
    var autoPresetID: String?
    var lastRestoredPresetID: String?

    init(key: String) { self.key = key }

    var embeddedSnapshotVersion: Int? { nil }

    mutating func refresh(from topology: ObservedTopology) {
        canonicalDescription = topology.identity.canonicalDescription
        displays = topology.displays
    }
}

/// preset-<id>.json
private struct PresetFile: VersionedFile {
    var version: Int
    var id: String
    var name: String
    var savedAt: Date
    var snapshot: Snapshot

    var embeddedSnapshotVersion: Int? { snapshot.version }
}
