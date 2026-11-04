import XCTest
@testable import Core

// SnapshotStoreTests — 存储原语验收（spec §7.4）。
// 接缝：SnapshotStore（拓扑键、原子写、滚动历史、损坏隔离、历史回退）。
// 日志经 spy LogWriting 捕获，不真写盘。
final class SnapshotStoreTests: XCTestCase {
    private var root: URL!
    private var store: SnapshotStore!
    private var logLines: [String]!

    override func setUpWithError() throws {
        root = try makeTempDir()
        logLines = []
        store = SnapshotStore(directory: root, log: LogSpy { [weak self] in self?.logLines.append($0) })
    }
    override func tearDownWithError() throws {
        // 恢复可能被收紧的目录权限，保证清理成功
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    private func snap(_ id: String) -> Snapshot {
        Snapshot(
            capturedAt: Date(timeIntervalSince1970: 0),
            topology: [TopologyDisplay(uuid: "U", localizedName: "d",
                                       frame: SnapshotDisplayFrame(x: 0, y: 0, w: 100, h: 100), orientation: 0)],
            spaces: [SnapshotSpace(displayUUID: "U", index: 1, kind: .user, fullscreenAppBundleID: nil)],
            windows: [SnapshotWindow(bundleID: "app.\(id)", title: id, siblingIndex: 0,
                                     displayUUID: "U", spaceIndex: 1,
                                     x: 0.1, y: 0.1, w: 0.5, h: 0.5, minimized: false)])
    }

    // MARK: 拓扑键

    /// 拓扑键 = 排序显示器 UUID 集合：与输入顺序无关
    func testTopologyKeyIsSortedDeterministic() {
        let a = "AAAA-1111-1111-1111-111111111111"
        let b = "BBBB-2222-2222-2222-222222222222"
        let c = "CCCC-3333-3333-3333-333333333333"
        XCTAssertEqual(SnapshotStore.topologyKey(forDisplayUUIDs: [a, b, c]),
                       SnapshotStore.topologyKey(forDisplayUUIDs: [c, a, b]))
        XCTAssertEqual(SnapshotStore.topologyKey(forDisplayUUIDs: [a, b, c]), "\(a)-\(b)-\(c)")
    }

    // MARK: 原子写

    /// 原子写契约：目标文件内容完整等于新数据；不留临时文件；覆盖写完整替换
    func testAtomicWriteLeavesCompleteFileOnly() throws {
        let url = root.appendingPathComponent("live-k.json")
        let first = try snap("a").encoded()
        try SnapshotStore.atomicWrite(first, to: url)
        XCTAssertEqual(try Data(contentsOf: url), first)

        let second = try snap("b").encoded()
        try SnapshotStore.atomicWrite(second, to: url)
        XCTAssertEqual(try Data(contentsOf: url), second, "覆盖写后必须是完整新内容")

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains(".tmp-") }
        XCTAssertTrue(leftovers.isEmpty, "不得残留临时文件：\(leftovers)")
    }

    /// 写入失败（目录不可写）时目标文件保留原完整内容，不留半截
    func testFailedAtomicWritePreservesPreviousContent() throws {
        let url = root.appendingPathComponent("live-k.json")
        let first = try snap("a").encoded()
        try SnapshotStore.atomicWrite(first, to: url)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        XCTAssertThrowsError(try SnapshotStore.atomicWrite(snap("b").encoded(), to: url))
        XCTAssertEqual(try Data(contentsOf: url), first, "写失败后旧内容必须原样保留")
    }

    // MARK: 滚动历史（现势 1 + 历史 4）

    func testRollingHistoryKeepsLivePlusFourSlots() throws {
        for id in ["s1", "s2", "s3", "s4", "s5", "s6"] {
            try store.write(snap(id), topologyKey: "k")
        }
        XCTAssertEqual(try Snapshot.decode(from: Data(contentsOf: store.liveURL(topologyKey: "k"))).windows[0].bundleID, "app.s6")
        func historySlot(_ n: Int) throws -> String {
            try Snapshot.decode(from: Data(contentsOf: store.historyURL(topologyKey: "k", slot: n))).windows[0].bundleID
        }
        XCTAssertEqual(try historySlot(1), "app.s5", "history-1 = 上一份现势")
        XCTAssertEqual(try historySlot(2), "app.s4")
        XCTAssertEqual(try historySlot(3), "app.s3")
        XCTAssertEqual(try historySlot(4), "app.s2", "超出 4 份的最旧快照被滚动丢弃（s1 无档）")
    }

    // MARK: 损坏隔离与历史回退

    func testCorruptLiveIsQuarantinedAndFallsBackToHistory() throws {
        try store.write(snap("good1"), topologyKey: "k")
        try store.write(snap("good2"), topologyKey: "k")  // live=good2, history-1=good1
        // 模拟写中断/磁盘损坏：直接把 live 覆盖成残缺字节
        try Data("{'version': 1, 截断".utf8).write(to: store.liveURL(topologyKey: "k"))

        let restored = store.loadLive(topologyKey: "k")
        XCTAssertEqual(restored?.windows[0].bundleID, "app.good1", "应回退最新有效历史")

        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("live-k.json.corrupt-") }, "损坏文件应改名挪开：\(files)")
        XCTAssertFalse(files.contains("live-k.json"), "挪开后原路径不得残留")
        XCTAssertTrue(logLines.contains { $0.contains("quarantine") && $0.contains("corrupt") }, "隔离必须记日志：\(logLines)")
    }

    /// 回退沿新鲜度顺序：history-1 也损坏 → 取 history-2
    func testFallbackDescendsHistorySlots() throws {
        try store.write(snap("h3"), topologyKey: "k")
        try store.write(snap("h2"), topologyKey: "k")
        try store.write(snap("h1"), topologyKey: "k")  // live=h1, history-1=h2, history-2=h3
        try Data("garbage".utf8).write(to: store.liveURL(topologyKey: "k"))
        try Data("garbage".utf8).write(to: store.historyURL(topologyKey: "k", slot: 1))

        let restored = store.loadLive(topologyKey: "k")
        XCTAssertEqual(restored?.windows[0].bundleID, "app.h3")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("history-1-k.json.corrupt-") })
        XCTAssertEqual(files.filter { $0.hasPrefix("history-2-k.json.corrupt-") }.count, 0, "有效历史不得误隔离")
    }

    /// 全部损坏：返回 nil，且每份损坏文件都被隔离
    func testAllCorruptYieldsNil() throws {
        try store.write(snap("x"), topologyKey: "k")
        try store.write(snap("y"), topologyKey: "k")
        for url in [store.liveURL(topologyKey: "k")] + (1...4).map({ store.historyURL(topologyKey: "k", slot: $0) })
        where FileManager.default.fileExists(atPath: url.path) {
            try Data("ÿÿÿ".utf8).write(to: url)
        }
        XCTAssertNil(store.loadLive(topologyKey: "k"))
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(files.filter { $0.contains(".corrupt-") }.count,
                       files.filter { $0.hasSuffix(".json") || $0.contains(".corrupt-") }.count,
                       "所有 json 文件都应被隔离：\(files)")
    }

    /// 未知更高 version 的现势快照：拒用 + 日志，但不隔离、回退历史（spec §7.3 不迁移）
    func testUnsupportedVersionRefusedNotQuarantined() throws {
        try store.write(snap("v1good"), topologyKey: "k")
        try store.write(snap("v1hist"), topologyKey: "k")
        var future = snap("future")
        future.version = 99
        try future.encoded().write(to: store.liveURL(topologyKey: "k"))

        let restored = store.loadLive(topologyKey: "k")
        XCTAssertEqual(restored?.windows[0].bundleID, "app.v1good", "拒用未来版本后应回退最新有效历史（history-1=v1good）")
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(files.contains("live-k.json"), "版本拒用不是损坏：文件必须原位保留")
        XCTAssertTrue(logLines.contains { $0.contains("unsupported-version") && $0.contains("99") }, "必须记拒用日志：\(logLines)")
    }

    /// 空目录 / 无快照：返回 nil 且不崩
    func testLoadLiveOnEmptyDirectoryReturnsNil() {
        XCTAssertNil(store.loadLive(topologyKey: "nonexistent"))
    }

    /// 拓扑键反拆：36 字符段 + "-" 连接（冻结格式）无歧义还原 UUID 集合
    func testTopologyKeyRoundTripParsesFixedWidthUUIDSegments() {
        let aUUID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let bUUID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let key = SnapshotStore.topologyKey(forDisplayUUIDs: [aUUID, bUUID])
        XCTAssertEqual(SnapshotStore.displayUUIDs(inTopologyKey: key)?.sorted(), [aUUID, bUUID])
        XCTAssertNil(SnapshotStore.displayUUIDs(inTopologyKey: "short-fake-key"), "非冻结格式拒拆")
    }
}

/// 测试 spy：只捕获日志行，不写盘
final class LogSpy: LogWriting {
    private let handler: (String) -> Void
    init(_ handler: @escaping (String) -> Void) { self.handler = handler }
    func write(_ line: String) { handler(line) }
}
