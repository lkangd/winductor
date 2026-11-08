import XCTest
@testable import Core

// SnapshotStoreTests — 文件原语验收（原子写、损坏隔离）。
// 接缝：SnapshotStore。live/history 布局已删（display-presets 票 02），预设布局见 PresetStoreTests。
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

    // MARK: 原子写

    /// 原子写契约：目标文件内容完整等于新数据；不留临时文件；覆盖写完整替换
    func testAtomicWriteLeavesCompleteFileOnly() throws {
        let url = root.appendingPathComponent("k.json")
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
        let url = root.appendingPathComponent("k.json")
        let first = try snap("a").encoded()
        try SnapshotStore.atomicWrite(first, to: url)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        XCTAssertThrowsError(try SnapshotStore.atomicWrite(snap("b").encoded(), to: url))
        XCTAssertEqual(try Data(contentsOf: url), first, "写失败后旧内容必须原样保留")
    }

    // MARK: 损坏隔离

    /// 隔离 = 改名 "<原名>.corrupt-<时间戳>"，原路径腾空；同秒重复隔离追加序号不覆盖
    func testQuarantineRenamesAsideWithoutClobbering() throws {
        let url = root.appendingPathComponent("k.json")
        try Data("garbage".utf8).write(to: url)
        let first = try XCTUnwrap(store.quarantine(url))
        try Data("garbage2".utf8).write(to: url)
        let second = try XCTUnwrap(store.quarantine(url))

        XCTAssertTrue(first.lastPathComponent.hasPrefix("k.json.corrupt-"))
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "挪开后原路径不得残留")
        XCTAssertEqual(try Data(contentsOf: first), Data("garbage".utf8))
    }
}

/// 测试 spy：只捕获日志行，不写盘
final class LogSpy: LogWriting {
    private let handler: (String) -> Void
    init(_ handler: @escaping (String) -> Void) { self.handler = handler }
    func write(_ line: String) { handler(line) }
}
