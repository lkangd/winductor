import XCTest
@testable import Core

// SchemaTests — 快照 schema v1 验收（spec §7.3 逐字段）。
// 接缝：Snapshot.decode/encoded 与版本守卫（unknown higher version 拒用）。
final class SchemaTests: XCTestCase {
    /// spec §7.3 原文示例 JSON（capturedAt 带 +08:00 偏移，作为独立真值）
    private static let specExample = """
    {
      "version": 1,
      "capturedAt": "2025-10-29T09:30:00+08:00",
      "topology": [
        { "uuid": "0A938E2D-1111-2222-3333-444455556666", "localizedName": "Dell U2723QE",
          "frame": {"x":0,"y":0,"w":2560,"h":1440}, "orientation": 1 }
      ],
      "spaces": [
        { "displayUUID": "0A938E2D-1111-2222-3333-444455556666", "index": 1, "kind": "user", "fullscreenAppBundleID": null },
        { "displayUUID": "0A938E2D-1111-2222-3333-444455556666", "index": 2, "kind": "fullscreen", "fullscreenAppBundleID": "com.google.Chrome" }
      ],
      "windows": [
        { "bundleID": "com.apple.Safari", "title": "邮件", "siblingIndex": 0,
          "displayUUID": "0A938E2D-1111-2222-3333-444455556666", "spaceIndex": 1,
          "x": 0.10, "y": 0.12, "w": 0.55, "h": 0.70, "minimized": false }
      ]
    }
    """

    func testSpecExampleDecodes() throws {
        let snap = try Snapshot.decode(from: Data(Self.specExample.utf8))
        XCTAssertEqual(snap.version, 1)
        XCTAssertEqual(snap.topology.count, 1)
        XCTAssertEqual(snap.topology[0].uuid, "0A938E2D-1111-2222-3333-444455556666")
        XCTAssertEqual(snap.topology[0].localizedName, "Dell U2723QE")
        XCTAssertEqual(snap.topology[0].frame, SnapshotDisplayFrame(x: 0, y: 0, w: 2560, h: 1440))
        XCTAssertEqual(snap.topology[0].orientation, 1)
        XCTAssertEqual(snap.spaces.count, 2)
        XCTAssertEqual(snap.spaces[0].kind, .user)
        XCTAssertNil(snap.spaces[0].fullscreenAppBundleID)
        XCTAssertEqual(snap.spaces[1].kind, .fullscreen)
        XCTAssertEqual(snap.spaces[1].fullscreenAppBundleID, "com.google.Chrome")
        XCTAssertEqual(snap.windows.count, 1)
        XCTAssertEqual(snap.windows[0].bundleID, "com.apple.Safari")
        XCTAssertEqual(snap.windows[0].title, "邮件")
        XCTAssertEqual(snap.windows[0].siblingIndex, 0)
        XCTAssertEqual(snap.windows[0].spaceIndex, 1)
        XCTAssertEqual(snap.windows[0].x, 0.10, accuracy: 1e-12)
        XCTAssertEqual(snap.windows[0].minimized, false)
    }

    /// 全字段编解码往返无损：任意合法快照 encode → decode → Equal
    func testRoundTripLossless() throws {
        let snap = Snapshot(
            capturedAt: Date(timeIntervalSince1970: 1_761_783_000),
            topology: [
                TopologyDisplay(uuid: "UUID-A", localizedName: "Built-in Retina Display",
                                frame: SnapshotDisplayFrame(x: -1512, y: 0, w: 1512, h: 982), orientation: 0),
                TopologyDisplay(uuid: "UUID-B", localizedName: "DELL P2419H (2)",
                                frame: SnapshotDisplayFrame(x: 1920, y: -419, w: 1080, h: 1920), orientation: 90),
            ],
            spaces: [
                SnapshotSpace(displayUUID: "UUID-A", index: 1, kind: .user, fullscreenAppBundleID: nil),
                SnapshotSpace(displayUUID: "UUID-B", index: 1, kind: .fullscreen,
                              fullscreenAppBundleID: "com.apple.Terminal"),
            ],
            windows: [
                SnapshotWindow(bundleID: "com.google.Chrome", title: "Neovim — 抽象",
                               siblingIndex: 2, displayUUID: "UUID-B", spaceIndex: 1,
                               x: 0.03333333, y: 0.5, w: 0.9, h: 0.4, minimized: true),
            ])
        let round = try Snapshot.decode(from: snap.encoded())
        XCTAssertEqual(round, snap)
        // 编码文本层面也必须可再次解码（JSON 合法性 + 时间戳稳定）
        let twice = try Snapshot.decode(from: round.encoded())
        XCTAssertEqual(twice, snap)
    }

    /// 未知更高 version：拒用并报 unsupportedVersion（不迁移，spec §7.3）
    func testUnknownHigherVersionRejected() {
        let json = Self.specExample.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 2")
        XCTAssertThrowsError(try Snapshot.decode(from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? SnapshotSchemaError, .unsupportedVersion(found: 2, supported: 1))
        }
    }

    /// 低于 1 的 version 同样拒用（schema 只有 v1 存在）
    func testInvalidLowerVersionRejected() {
        let json = Self.specExample.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 0")
        XCTAssertThrowsError(try Snapshot.decode(from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? SnapshotSchemaError, .invalidVersion(found: 0))
        }
    }

    /// 缺 version 字段 = 解析失败（损坏路径，交由存储层隔离）
    func testMissingVersionIsParseError() {
        let json = Self.specExample.replacingOccurrences(of: "\"version\": 1,", with: "")
        XCTAssertThrowsError(try Snapshot.decode(from: Data(json.utf8))) { error in
            XCTAssertTrue(error is DecodingError, "缺 version 应表现为解析错误，实际 \(error)")
        }
    }
}
