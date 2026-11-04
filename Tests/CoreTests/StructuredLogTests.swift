import XCTest
@testable import Core

// StructuredLogTests — 日志行格式（spec §10.4）与文件 sink（延迟建目录）验收。
// 接缝：StructuredLog.restoreLine/degradeLine、FileLogSink(LogWriting)。
final class StructuredLogTests: XCTestCase {
    /// [restore] 行逐字段按 spec §10.4 原文格式
    func testRestoreLineFormat() {
        let line = StructuredLog.restoreLine(
            layer: 2, wid: 173, app: "com.google.Chrome", action: .moveToSpace,
            target: "0A938E2D-1111-2222-3333-444455556666/2",
            before: "(100,200,800,600)", after: "(100,200,800,600)", result: .ok)
        XCTAssertEqual(line,
            "[restore] L2 wid=173 app=com.google.Chrome action=move-to-space "
            + "target=0A938E2D-1111-2222-3333-444455556666/2 "
            + "before=(100,200,800,600) after=(100,200,800,600) result=ok")
    }

    /// skip 行的注册扩展键（reason=/detail=）接在冻结字段之后；缺省时与冻结格式逐字节一致
    func testRestoreLineSkipExtensionKeys() {
        let line = StructuredLog.restoreLine(
            layer: 2, wid: 0, app: "com.t.gone", action: .moveToSpace,
            target: "A-uuid/1", before: "-", after: "-", result: .skip, reason: "app-not-running")
        XCTAssertEqual(line,
            "[restore] L2 wid=0 app=com.t.gone action=move-to-space "
            + "target=A-uuid/1 before=- after=- result=skip reason=app-not-running")

        let withDetail = StructuredLog.restoreLine(
            layer: 3, wid: 9, app: "com.t.fs", action: .fullscreen,
            target: "A-uuid/2", before: "b", after: "-", result: .skip,
            reason: "fullscreen-exit-pending", detail: "already-at-target")
        XCTAssertTrue(withDetail.hasSuffix("result=skip reason=fullscreen-exit-pending detail=already-at-target"),
                      "实际行：\(withDetail)")
    }

    /// [degrade] 行逐字段按 spec §10.4 原文格式
    func testDegradeLineFormat() {
        let line = StructuredLog.degradeLine(layer: 2, reason: "probe-miss", detail: "SLSBridgedMoveWindowsToManagedSpaceOperation not found")
        XCTAssertEqual(line,
            "[degrade] layer=L2 reason=probe-miss detail=SLSBridgedMoveWindowsToManagedSpaceOperation not found")
    }

    /// 文件 sink：目录延迟创建（首次 write 才建），行前缀 ISO8601 时间戳，追加写
    func testFileSinkLazyDirectoryAndAppend() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("logs")
        let sink = FileLogSink(directory: dir, fileName: "test.log")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "目录应延迟到首次写入才创建")
        sink.write("[degrade] layer=L1 reason=probe-miss detail=x")
        sink.write("[restore] L1 wid=1 app=a action=position target=t before=b after=a result=skip")
        let text = try String(contentsOf: dir.appendingPathComponent("test.log"), encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "第二次写入应追加而非覆盖")
        XCTAssertTrue(lines[0].hasSuffix(" [degrade] layer=L1 reason=probe-miss detail=x"), "实际行：\(lines[0])")
        XCTAssertTrue(lines[1].hasSuffix(" result=skip"))
        // 时间戳前缀：ISO8601 可解析
        let prefix = lines[0].dropLast(" [degrade] layer=L1 reason=probe-miss detail=x".count)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: String(prefix)) ?? ISO8601DateFormatter.withFractionalSeconds.date(from: String(prefix)),
                        "行首应为 ISO8601 时间戳：\(prefix)")
    }
}

extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
