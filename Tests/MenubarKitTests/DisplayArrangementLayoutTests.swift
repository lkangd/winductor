import Core
import CoreGraphics
import XCTest
@testable import MenubarKit

// display-presets 票 07：排列图布局计算（display-presets spec §6.4 右上排列图，仿系统设置「显示器」）。
// 接缝：DisplayArrangementLayout.layout(_:in:padding:) —— 展示数据（全局 point frame）→ 画布内缩放后的视图矩形。
// 独立事实来源：手算的等比缩放 + 居中结果（画布左上原点、y 向下，与 CGDisplayBounds 全局坐标同向）。
final class DisplayArrangementLayoutTests: XCTestCase {
    private func display(_ uuid: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                         name: String = "屏", pixels: (Int, Int)? = nil, rotation: Int = 0) -> TopologyDisplayInfo {
        TopologyDisplayInfo(uuid: uuid, name: name, frame: SnapshotDisplayFrame(x: x, y: y, w: w, h: h),
                            pixelWidth: pixels?.0 ?? Int(w) * 2, pixelHeight: pixels?.1 ?? Int(h) * 2,
                            rotation: rotation)
    }

    /// 并排两屏：按包围盒等比缩放，短边方向居中
    func testSideBySideScreensScaleToFitAndCenterVertically() {
        let arranged = DisplayArrangementLayout.layout(
            [display("a", 0, 0, 2000, 1000), display("b", 2000, 0, 2000, 1000)],
            in: CGSize(width: 400, height: 300), padding: 0)

        XCTAssertEqual(arranged.map(\.uuid), ["a", "b"])
        XCTAssertEqual(arranged.map(\.rect), [
            CGRect(x: 0, y: 100, width: 200, height: 100),
            CGRect(x: 200, y: 100, width: 200, height: 100),
        ])
    }

    /// 右侧竖屏且上移（负 y）：竖屏照实画成高矩形，相对位置保留
    func testPortraitScreenDrawnTallAtItsRelativeOffset() {
        let arranged = DisplayArrangementLayout.layout(
            [display("main", 0, 0, 1920, 1080), display("tall", 1920, -420, 1080, 1920, rotation: 90)],
            in: CGSize(width: 300, height: 300), padding: 0)

        XCTAssertEqual(arranged.map(\.rect), [
            CGRect(x: 0, y: 96, width: 192, height: 108),
            CGRect(x: 192, y: 54, width: 108, height: 192),
        ])
    }

    /// 上下堆叠（上屏较窄且居中偏移）：纵向受限时横向居中
    func testStackedScreensKeepVerticalOrderAndHorizontalOffset() {
        let arranged = DisplayArrangementLayout.layout(
            [display("main", 0, 0, 2560, 1440), display("top", 320, -1080, 1920, 1080)],
            in: CGSize(width: 512, height: 252), padding: 0)

        XCTAssertEqual(arranged.map(\.rect), [
            CGRect(x: 128, y: 108, width: 256, height: 144),
            CGRect(x: 160, y: 0, width: 192, height: 108),
        ])
    }

    /// 四屏田字格 + 内边距：可用区 = 画布减四周 padding
    func testFourScreenGridRespectsPadding() {
        let arranged = DisplayArrangementLayout.layout(
            [display("tl", 0, 0, 1000, 500), display("tr", 1000, 0, 1000, 500),
             display("bl", 0, 500, 1000, 500), display("br", 1000, 500, 1000, 500)],
            in: CGSize(width: 220, height: 120), padding: 10)

        XCTAssertEqual(arranged.map(\.rect), [
            CGRect(x: 10, y: 10, width: 100, height: 50),
            CGRect(x: 110, y: 10, width: 100, height: 50),
            CGRect(x: 10, y: 60, width: 100, height: 50),
            CGRect(x: 110, y: 60, width: 100, height: 50),
        ])
    }

    /// 标注：屏名 + 分辨率（像素，「宽 × 高」）；是否内置屏（刘海）随展示数据，旧数据缺省按非内置
    func testLabelsCarryNameAndPixelResolution() {
        let arranged = DisplayArrangementLayout.layout(
            [display("a", 0, 0, 1920, 1080, name: "DELL U2723QE", pixels: (3840, 2160))],
            in: CGSize(width: 100, height: 100))

        XCTAssertEqual(arranged.first?.name, "DELL U2723QE")
        XCTAssertEqual(arranged.first?.resolutionText, "3840 × 2160")
        XCTAssertEqual(arranged.first?.isBuiltin, false)

        var builtin = display("b", 0, 0, 1512, 982)
        builtin.isBuiltin = true
        XCTAssertEqual(DisplayArrangementLayout.layout([builtin], in: CGSize(width: 100, height: 100)).first?.isBuiltin,
                       true)
    }

    /// 同名屏按排列顺序加「#n」，与预设详情卡片的屏名一致（点屏后对得上卡片，ui-refactor 票 04）
    func testSameNamedScreensDisambiguatedLikeDetailCards() {
        let arranged = DisplayArrangementLayout.layout(
            [display("a", 0, 0, 2560, 1440, name: "DELL"), display("b", 2560, 0, 2560, 1440, name: "DELL"),
             display("c", 5120, 0, 1512, 982, name: "内置")],
            in: CGSize(width: 300, height: 100))

        XCTAssertEqual(arranged.map(\.name), ["DELL #1", "DELL #2", "内置"])
    }

    /// 无屏 / 画布小于内边距：空结果，不除零
    func testEmptyInputOrDegenerateCanvasYieldsNothing() {
        XCTAssertEqual(DisplayArrangementLayout.layout([], in: CGSize(width: 100, height: 100)), [])
        XCTAssertEqual(DisplayArrangementLayout.layout([display("a", 0, 0, 100, 100)],
                                                       in: CGSize(width: 10, height: 10), padding: 10), [])
    }
}
