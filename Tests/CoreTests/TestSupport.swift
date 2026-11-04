import Foundation
import XCTest

// TestSupport — CoreTests 共用工具：隔离的临时目录（每个用例独享，用完清理）。
enum TestSupport {
    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("winductor-coretests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
extension XCTestCase {
    func makeTempDir() throws -> URL { try TestSupport.makeTempDir() }
}
