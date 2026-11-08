import XCTest
@testable import Core

// TransitionalLiveSnapshotsTests — 过渡期内存现势快照的旧口径拓扑键（票 03/04 删除时一并删除）。
final class TransitionalLiveSnapshotsTests: XCTestCase {
    /// 旧口径键 = 排序显示器 UUID 集合：与输入顺序无关
    func testTopologyKeyIsSortedDeterministic() {
        let a = "AAAA-1111-1111-1111-111111111111"
        let b = "BBBB-2222-2222-2222-222222222222"
        let c = "CCCC-3333-3333-3333-333333333333"
        XCTAssertEqual(TransitionalLiveSnapshots.topologyKey(forDisplayUUIDs: [a, b, c]),
                       TransitionalLiveSnapshots.topologyKey(forDisplayUUIDs: [c, a, b]))
        XCTAssertEqual(TransitionalLiveSnapshots.topologyKey(forDisplayUUIDs: [a, b, c]), "\(a)-\(b)-\(c)")
    }

    /// 键反拆：36 字符段 + "-" 连接无歧义还原 UUID 集合
    func testTopologyKeyRoundTripParsesFixedWidthUUIDSegments() {
        let aUUID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let bUUID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let key = TransitionalLiveSnapshots.topologyKey(forDisplayUUIDs: [aUUID, bUUID])
        XCTAssertEqual(TransitionalLiveSnapshots.displayUUIDs(inTopologyKey: key)?.sorted(), [aUUID, bUUID])
        XCTAssertNil(TransitionalLiveSnapshots.displayUUIDs(inTopologyKey: "short-fake-key"), "非该格式拒拆")
        let notUUID = String(repeating: "x", count: 36)
        XCTAssertNil(TransitionalLiveSnapshots.displayUUIDs(inTopologyKey: "\(aUUID)-\(notUUID)"), "段长对但不是 UUID：拒拆")
    }

    /// 每拓扑一份、覆盖写；不落盘
    func testWriteOverwritesPerTopologyInMemory() {
        let store = TransitionalLiveSnapshots()
        let a = Snapshot(capturedAt: Date(timeIntervalSince1970: 1), topology: [], spaces: [], windows: [])
        let b = Snapshot(capturedAt: Date(timeIntervalSince1970: 2), topology: [], spaces: [], windows: [])
        store.write(a, topologyKey: "k1")
        store.write(b, topologyKey: "k1")
        store.write(a, topologyKey: "k2")
        XCTAssertEqual(store.loadLive(topologyKey: "k1"), b)
        XCTAssertEqual(store.topologyKeys, ["k1", "k2"])
        XCTAssertNil(store.loadLive(topologyKey: "k3"))
    }
}
