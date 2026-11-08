import Foundation

// ConservativeMatch.swift — 保守匹配核心（spec §7.1）。票 11 拥有本文件。
// verify CLI 与 app 恢复管线共用同一份实现（08 #1，禁止出现第二份）。
// 匹配规则：
//   一级：匹配键 = bundleID + 窗口标题 + 兄弟序；兄弟序 = 同应用同标题窗口按
//         「先 y 后 x」排序取序号（快照侧落盘时已定序，存活侧此处现算）。
//   二级（几何兜底）：标题失配后，仅同应用、目标窗口未被其他快照条目占用、
//         比例几何位置最近邻、欧氏距离 ≤ 0.15（spec §10.3）。
//   仍配不上 → 跳过（保守匹配：不猜、不启动，spec §6.4）。

/// 存活窗口的最小匹配描述（恢复引擎实况收集与 verify 枚举共用）。
/// x/y/w/h 为所属屏归一比例坐标；cgWindowID 仅会话内辅助，不参与匹配键（spec §7.1）。
public struct LiveWindow: Equatable, Sendable {
    public let cgWindowID: UInt32
    public let bundleID: String
    public let title: String
    public let x: Double, y: Double, w: Double, h: Double
    public let minimized: Bool

    public init(cgWindowID: UInt32, bundleID: String, title: String,
                x: Double, y: Double, w: Double, h: Double, minimized: Bool) {
        self.cgWindowID = cgWindowID
        self.bundleID = bundleID
        self.title = title
        self.x = x; self.y = y; self.w = w; self.h = h
        self.minimized = minimized
    }
}

/// 兄弟序排序所需的坐标子集（快照窗口与存活窗口共用）
public protocol SiblingSortable {
    var x: Double { get }
    var y: Double { get }
}
extension LiveWindow: SiblingSortable {}
extension SnapshotWindow: SiblingSortable {}

/// 一条配对结果：快照条目 ↔ 存活窗口
public struct WindowMatch: Equatable, Sendable {
    public let snapshotIndex: Int
    public let liveIndex: Int
    /// true = 二级几何兜底配上的（标题失配）
    public let viaGeometryFallback: Bool
}

public struct MatchOutcome: Equatable, Sendable {
    /// 全部配对（按 snapshotIndex 升序）
    public let matches: [WindowMatch]
    /// 未配上任何存活窗口的快照条目下标（restore 语义 = 跳过不动）
    public let unmatchedSnapshotIndexes: [Int]
    /// 快照之外的存活窗口下标（保守匹配「不动」集合，verify 用于预期跳过核对）
    public let unmatchedLiveIndexes: [Int]
}

public enum ConservativeMatcher {
    /// 几何兜底距离阈值（比例坐标，spec §10.3）
    public static let geometryFallbackThreshold = 0.15

    /// 兄弟序排序：「先 y 后 x」升序（spec §7.1）。快照侧与存活侧同一规则。
    public static func siblingOrder<T: SiblingSortable>(_ windows: [T]) -> [T] {
        windows.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }

    /// 保守匹配主入口（app 与 verify 共用）。
    /// 先一级（匹配键）后二级（几何兜底），占用互斥贯穿两轮：
    /// 一个存活窗口最多被一个快照条目占用；同轮竞争按快照数组序定先后。
    public static func match(snapshotWindows: [SnapshotWindow], liveWindows: [LiveWindow]) -> MatchOutcome {
        // 1) 存活侧按 (bundleID, title) 分组，组内先 y 后 x 定兄弟序（排序前记录原下标）
        var liveSiblingIndex = [Int: Int]()
        var grouped: [BundleTitleKey: [Int]] = [:]
        for (index, window) in liveWindows.enumerated() {
            grouped[BundleTitleKey(bundleID: window.bundleID, title: window.title), default: []].append(index)
        }
        for (_, members) in grouped {
            let tagged = members.map { TaggedIndex(index: $0, x: liveWindows[$0].x, y: liveWindows[$0].y) }
            for (rank, tagged) in siblingOrder(tagged).enumerated() {
                liveSiblingIndex[tagged.index] = rank
            }
        }

        var occupied = Set<Int>()
        var matched = [WindowMatch]()
        var fallbackCandidates = [Int]()

        // 2) 一级匹配：bundleID + 标题 + 兄弟序（同键多条快照条目按数组序先到先得）
        var claimedLiveKeys = Set<BundleTitleSibling>()
        for (s, snapshot) in snapshotWindows.enumerated() {
            let key = BundleTitleSibling(bundleID: snapshot.bundleID, title: snapshot.title,
                                         siblingIndex: snapshot.siblingIndex)
            var found: Int?
            if !claimedLiveKeys.contains(key) {
                for (li, window) in liveWindows.enumerated() where !occupied.contains(li) {
                    if window.bundleID == snapshot.bundleID,
                       window.title == snapshot.title,
                       liveSiblingIndex[li] == snapshot.siblingIndex {
                        found = li
                        break
                    }
                }
            }
            if let found {
                claimedLiveKeys.insert(key)
                occupied.insert(found)
                matched.append(WindowMatch(snapshotIndex: s, liveIndex: found, viaGeometryFallback: false))
            } else {
                fallbackCandidates.append(s)
            }
        }

        // 3) 二级几何兜底：同应用、未被占用、比例位置最近邻、距离 ≤ 阈值（快照序定先后）
        for s in fallbackCandidates {
            let snapshot = snapshotWindows[s]
            var best: (index: Int, distance: Double)?
            for (l, window) in liveWindows.enumerated() {
                guard window.bundleID == snapshot.bundleID, !occupied.contains(l) else { continue }
                let d = hypot(snapshot.x - window.x, snapshot.y - window.y)
                if d <= geometryFallbackThreshold, best == nil || d < best!.distance {
                    best = (l, d)
                }
            }
            if let best {
                occupied.insert(best.index)
                matched.append(WindowMatch(snapshotIndex: s, liveIndex: best.index, viaGeometryFallback: true))
            }
        }

        let matchedSnapshots = Set(matched.map(\.snapshotIndex))
        return MatchOutcome(
            matches: matched.sorted { $0.snapshotIndex < $1.snapshotIndex },
            unmatchedSnapshotIndexes: snapshotWindows.indices.filter { !matchedSnapshots.contains($0) },
            unmatchedLiveIndexes: liveWindows.indices.filter { !occupied.contains($0) })
    }
}

private struct BundleTitleKey: Hashable {
    let bundleID: String
    let title: String
}

private struct BundleTitleSibling: Hashable {
    let bundleID: String
    let title: String
    let siblingIndex: Int
}

/// 排序辅助：携带原下标参与兄弟序排序
private struct TaggedIndex: SiblingSortable {
    let index: Int
    let x: Double
    let y: Double
}
