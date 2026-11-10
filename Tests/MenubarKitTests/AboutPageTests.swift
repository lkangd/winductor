import AppKit
import XCTest
@testable import MenubarKit

// ui-refactor 票 08：关于页标题旁的透明底主体在上一版 1.1 倍的基础上再放大 20%。
// 独立事实来源：系统字体 34pt heavy 的大写字高（capHeight），主体原图宽高比 841:696。
@MainActor
final class AboutPageTests: XCTestCase {
    /// 主体显示高 = 34pt heavy 大写字高 × 1.1 × 1.2；宽按原图比例，不变形
    func testSubjectIsTwentyPercentLargerThanPreviousSize() throws {
        let subject = try XCTUnwrap(BrandAssets.appIconSubject())
        let capHeight = NSFont.systemFont(ofSize: 34, weight: .heavy).capHeight
        let size = AboutPage.subjectSize(for: subject)
        XCTAssertEqual(size.height, capHeight * 1.1 * 1.2, accuracy: 0.001)
        XCTAssertEqual(size.width / size.height, 841.0 / 696.0, accuracy: 0.001)
        XCTAssertGreaterThan(capHeight, 20, "34pt 字体的字高应在 24pt 上下")
    }
}
