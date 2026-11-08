import Foundation

// TransitionalLiveSnapshots.swift — 过渡期内存现势快照（票 02 → 票 03/04 之间的桥）。
// 票 02 删除了 SnapshotStore 的 live/history 落盘布局；旧链路（SnapshotEngine 后台轮询 → TriggerChain
// 冻结点账本 / 自动恢复、菜单状态行与「立即恢复」）仍需「每拓扑最新一份快照」，在其被票 03（一次性拍快照）
// 与票 04（按预设判定的触发链）替换前改由本类型在进程内存中承载：不落盘、不读任何旧 live-*/history-* 文件。
// 键沿用旧口径「排序显示器 UUID 以 "-" 连接」（仅本过渡链路内部使用；预设与回滚快照用 TopologyIdentity 键）。
// 票 03/04 落地后整体删除。

public final class TransitionalLiveSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var byKey: [String: Snapshot] = [:]
    private let log: LogWriting?

    public init(log: LogWriting? = nil) {
        self.log = log
    }

    /// 旧口径拓扑键 = 排序显示器 UUID 集合以 "-" 连接
    public static func topologyKey(forDisplayUUIDs uuids: [String]) -> String {
        uuids.sorted().joined(separator: "-")
    }

    /// 旧口径拓扑键反拆 UUID 集合：键 = 36 字符 UUID 段（段内含连字符）以 "-" 连接；非该格式返回 nil
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
            guard let end = key.index(index, offsetBy: 36, limitedBy: key.endIndex),
                  UUID(uuidString: String(key[index..<end])) != nil else {
                return nil
            }
            uuids.append(String(key[index..<end]))
            index = end
        }
        return uuids
    }

    /// 写入（覆盖该拓扑的上一份）
    public func write(_ snapshot: Snapshot, topologyKey key: String) {
        lock.lock(); byKey[key] = snapshot; lock.unlock()
        log?.write("[snapshot] action=write path=live-\(key)(memory) result=ok detail=windows=\(snapshot.windows.count)")
    }

    public func loadLive(topologyKey key: String) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        return byKey[key]
    }

    /// 已有快照的全部拓扑键（字典序）
    public var topologyKeys: [String] {
        lock.lock(); defer { lock.unlock() }
        return byKey.keys.sorted()
    }
}
