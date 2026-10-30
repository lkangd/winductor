import AppKit
import XCTest
@testable import MenubarKit

// 票 18：未就绪警示点测试（spec §8.1 图标三态之二）。
// 接缝：WarningDotOverlay.show/hide 对任意容器视图的叠加行为（测试用裸 NSView，
//       无需窗口服务器连接——NSStatusBar 在无 Aqua 会话的测试宿主内会崩溃）。
//       StatusItemController.setShowsWarningDot 仅是把按钮容器委托给它（活体验证在打包 .app 步骤）。
final class WarningDotOverlayTests: XCTestCase {
    private let container = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))

    private var warningDotCount: Int {
        container.subviews.filter { $0.identifier == WarningDotOverlay.identifier }.count
    }

    /// 常态：无警示点（spec §8.1「正常（网格图形）」）
    func testNoWarningDotInitially() {
        XCTAssertEqual(warningDotCount, 0)
    }

    /// 未就绪：出现警示点；重复开启幂等；关闭移除（§8.1「同图 + 黄色警示点」）
    func testShowIsIdempotentAndHideRemoves() {
        WarningDotOverlay.show(on: container)
        XCTAssertEqual(warningDotCount, 1)
        WarningDotOverlay.show(on: container)
        XCTAssertEqual(warningDotCount, 1, "重复开启不应叠加多个点")

        WarningDotOverlay.hide(from: container)
        XCTAssertEqual(warningDotCount, 0)
        WarningDotOverlay.hide(from: container)  // 幂等
        XCTAssertEqual(warningDotCount, 0)
    }

    /// 警示点是独立子视图叠加，不动容器既有内容（§8.1：未就绪=同图加点，非换图）
    func testOverlayDoesNotTouchContainerContent() {
        let placeholder = NSView(frame: .zero)
        container.addSubview(placeholder)
        WarningDotOverlay.show(on: container)
        XCTAssertTrue(container.subviews.contains(placeholder), "叠加不应移除既有内容")
    }
}
