import SwiftUI
import XCTest
@testable import MenubarKit

// ui-refactor 评审修复：侧栏前台/失焦样式的判定（spec §5.2「前台（key）：图标强调色…；失焦：图标与文字转次要灰」）。
// 接缝：EnvironmentValues.isMainWindowKey(_:) —— 只有窗口本身是 key 才算前台；同应用的其他窗口（授权窗、NSAlert）为 key 时
// 主窗口若报 .active，应转失焦样式。（直接测判定函数：EnvironmentValues 写入 .active 会被归一成 .key，无法经环境构造。）
final class MainWindowStyleTests: XCTestCase {
    func testOnlyKeyCountsAsForeground() {
        XCTAssertTrue(EnvironmentValues.isMainWindowKey(.key))
        XCTAssertFalse(EnvironmentValues.isMainWindowKey(.active), "同应用其他窗口为 key 时转失焦样式")
        XCTAssertFalse(EnvironmentValues.isMainWindowKey(.inactive))
    }
}
