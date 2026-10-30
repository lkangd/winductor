import XCTest
@testable import MenubarKit

// 票 19：能力状态行文案（spec §8.5「启动时探测…决定能力状态行」）。
// 接缝：CapabilityStatusLine.title(for:)——按层可用性产出菜单能力状态行标题。
// 独立事实来源：spec §8.5 逐字引文（「全部可用」／「以下恢复层不可用：Space 归属、最小化窗口归位（详见日志）」）。
final class CapabilityStatusLineTests: XCTestCase {
    private func layer(_ number: Int, available: Bool) -> CapabilityLayerStatus {
        CapabilityLayerStatus(layerNumber: number, displayName: CapabilityLayerStatus.name(forLayerNumber: number), available: available)
    }

    /// 全部可用：「能力状态：全部可用」（spec §8.2 骨架逐字）
    func testAllAvailableShowsVerbatimReady() {
        let layers = [layer(2, available: true), layer(3, available: true), layer(4, available: true)]
        XCTAssertEqual(CapabilityStatusLine.title(for: layers), "能力状态：全部可用")
    }

    /// 降级逐层列出：spec §8.5 逐字（L2+L4 不可用、L3 可用 → 按层序列出不可用者）
    func testDegradedListsUnavailableLayersVerbatim() {
        let layers = [layer(2, available: false), layer(3, available: true), layer(4, available: false)]
        XCTAssertEqual(CapabilityStatusLine.title(for: layers),
                       "能力状态：以下恢复层不可用：Space 归属、最小化窗口归位（详见日志）")
    }

    /// 单层降级（L2 桥接失效最常见）
    func testSingleDegradedLayer() {
        let layers = [layer(2, available: false), layer(3, available: true), layer(4, available: true)]
        XCTAssertEqual(CapabilityStatusLine.title(for: layers),
                       "能力状态：以下恢复层不可用：Space 归属（详见日志）")
    }

    /// 层号 → 层名映射（§8.5 词汇：Space 归属、全屏状态、最小化窗口归位；与通知附注同源）
    func testLayerDisplayNames() {
        XCTAssertEqual(CapabilityLayerStatus.name(forLayerNumber: 2), "Space 归属")
        XCTAssertEqual(CapabilityLayerStatus.name(forLayerNumber: 3), "全屏状态")
        XCTAssertEqual(CapabilityLayerStatus.name(forLayerNumber: 4), "最小化窗口归位")
    }
}
