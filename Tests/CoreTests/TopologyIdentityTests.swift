import CoreGraphics
import XCTest
@testable import Core

// TopologyIdentityTests — 拓扑身份验收（spec §3.1/§3.2/§3.3，ADR 0002）。
// 接缝：ObservedTopology(screens:)（纯函数：屏列表 → 拓扑身份 + 展示数据 + 镜像标记）。
// 坐标口径同 CGDisplayBounds：主屏左上角为原点、y 向下的 point 坐标。
final class TopologyIdentityTests: XCTestCase {
    private let main = "11111111-1111-1111-1111-111111111111"
    private let laptop = "22222222-2222-2222-2222-222222222222"
    private let side = "33333333-3333-3333-3333-333333333333"

    private func screen(_ uuid: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                        rotation: Int = 0, mirrored: Bool = false, name: String = "D",
                        pixels: (Int, Int)? = nil) -> TopologyScreen {
        TopologyScreen(uuid: uuid, name: name, frame: CGRect(x: x, y: y, width: w, height: h),
                       pixelWidth: pixels?.0 ?? Int(w * 2), pixelHeight: pixels?.1 ?? Int(h * 2),
                       rotation: rotation, isMirrored: mirrored)
    }

    private func key(_ screens: [TopologyScreen]) -> String {
        ObservedTopology(screens: screens).identity.key
    }

    /// 基准三屏：内置屏在左、中屏为主屏、右侧竖屏（旋转 90）
    private func home() -> [TopologyScreen] {
        [screen(laptop, -1512, 400, 1512, 982),
         screen(main, 0, 0, 2560, 1440),
         screen(side, 2560, -200, 1440, 2560, rotation: 90)]
    }

    // MARK: 枚举顺序无关

    func testKeyIsIndependentOfEnumerationOrder() {
        let screens = home()
        XCTAssertEqual(key(screens), key(screens.reversed()))
        XCTAssertEqual(key(screens), key([screens[1], screens[2], screens[0]]))
        XCTAssertEqual(ObservedTopology(screens: screens).identity.canonicalDescription,
                       ObservedTopology(screens: screens.reversed()).identity.canonicalDescription)
    }

    // MARK: spec §3.1 场景校验

    /// 右侧竖屏拖到左边（内置屏左侧）→ 另一拓扑
    func testMovingScreenToAnotherEdgeChangesKey() {
        var moved = home()
        moved[2] = screen(side, -1512 - 1440, -100, 1440, 2560, rotation: 90)
        XCTAssertNotEqual(key(home()), key(moved))
    }

    /// 右侧竖屏在系统设置里往上拖一点（沿边偏移变化）→ 同一拓扑
    func testNudgingAlongSameEdgeKeepsKey() {
        var nudged = home()
        nudged[2] = screen(side, 2560, -600, 1440, 2560, rotation: 90)
        XCTAssertEqual(key(home()), key(nudged))
    }

    /// 中屏分辨率 4K → 1440p：中屏 point 尺寸变化，右屏原点随之漂移 → 同一拓扑
    func testChangingResolutionKeepsKey() {
        let changed = [screen(laptop, -1512, 400, 1512, 982),
                       screen(main, 0, 0, 3840, 2160, pixels: (3840, 2160)),
                       screen(side, 3840, -200, 1440, 2560, rotation: 90)]
        XCTAssertEqual(key(home()), key(changed))
    }

    /// 换主屏（内置屏成为原点）：全部 frame 整体平移 → 同一拓扑
    func testChangingPrimaryKeepsKey() {
        let shifted = home().map {
            screen($0.uuid, $0.frame.minX + 1512, $0.frame.minY - 400, $0.frame.width, $0.frame.height,
                   rotation: $0.rotation)
        }
        XCTAssertEqual(key(home()), key(shifted))
    }

    /// 竖屏转回横屏 → 另一拓扑
    func testRotationChangesKey() {
        var rotated = home()
        rotated[2] = screen(side, 2560, 0, 2560, 1440, rotation: 0)
        XCTAssertNotEqual(key(home()), key(rotated))
    }

    /// 改分辨率导致其他屏原点漂移：整体平移 + 缩放仍同键
    func testWholeLayoutTranslatedAndScaledKeepsKey() {
        let drifted = home().map {
            screen($0.uuid, $0.frame.minX * 1.5 - 300, $0.frame.minY * 1.5 + 77,
                   $0.frame.width * 1.5, $0.frame.height * 1.5, rotation: $0.rotation)
        }
        XCTAssertEqual(key(home()), key(drifted))
    }

    /// 贴合容差：点坐标取整误差（缝隙/重叠 1pt）不影响邻接判定
    func testAdjacencyToleratesRoundingError() {
        let jittered = [screen(laptop, -1513, 400, 1512, 982),
                        screen(main, 0, 0, 2560, 1440),
                        screen(side, 2559, -200, 1440, 2560, rotation: 90)]
        XCTAssertEqual(key(home()), key(jittered))
    }

    /// UUID 集合不同 → 另一拓扑（同排列换一块屏）
    func testDifferentDisplaySetChangesKey() {
        var swapped = home()
        swapped[0] = screen("44444444-4444-4444-4444-444444444444", -1512, 400, 1512, 982)
        XCTAssertNotEqual(key(home()), key(swapped))
    }

    // MARK: 屏数与排列形态

    func testSingleScreenKeyIgnoresResolutionAndOrigin() {
        XCTAssertEqual(key([screen(laptop, 0, 0, 1512, 982)]),
                       key([screen(laptop, 0, 0, 1800, 1169)]))
        XCTAssertNotEqual(key([screen(laptop, 0, 0, 1512, 982)]),
                          key([screen(main, 0, 0, 1512, 982)]))
    }

    /// 两屏左右互换 → 另一拓扑
    func testTwoScreensSwappingSidesChangesKey() {
        let a = [screen(laptop, -1512, 200, 1512, 982), screen(main, 0, 0, 2560, 1440)]
        let b = [screen(laptop, 2560, 200, 1512, 982), screen(main, 0, 0, 2560, 1440)]
        XCTAssertNotEqual(key(a), key(b))
    }

    /// 上下堆叠：上下互换异键；左右错开偏移同键
    func testStackedVertically() {
        let stacked = [screen(main, 0, 0, 2560, 1440), screen(laptop, 500, 1440, 1512, 982)]
        let offset = [screen(main, 0, 0, 2560, 1440), screen(laptop, 0, 1440, 1512, 982)]
        let flipped = [screen(main, 0, 0, 2560, 1440), screen(laptop, 500, -982, 1512, 982)]
        XCTAssertEqual(key(stacked), key(offset))
        XCTAssertNotEqual(key(stacked), key(flipped))
        XCTAssertNotEqual(key(stacked), key([screen(main, 0, 0, 2560, 1440), screen(laptop, 2560, 0, 1512, 982)]),
                          "下方 vs 右侧是不同的边")
    }

    /// L 形：A 右接 B、下接 C；把 C 挪到 B 下方 → 另一拓扑
    func testLShape() {
        let a = main, b = laptop, c = side
        let lShape = [screen(a, 0, 0, 1920, 1080), screen(b, 1920, 0, 1920, 1080), screen(c, 0, 1080, 1920, 1080)]
        let other = [screen(a, 0, 0, 1920, 1080), screen(b, 1920, 0, 1920, 1080), screen(c, 1920, 1080, 1920, 1080)]
        XCTAssertNotEqual(key(lShape), key(other))
        XCTAssertEqual(key(lShape), key(lShape.reversed()))
    }

    /// 四屏：主屏上方两块屏（沿边先后）+ 右侧一块。上方两块之间留缝（彼此不相邻），
    /// 先后仍参与身份：互换 → 另一拓扑
    func testFourScreensOrderAlongSharedEdge() {
        let t1 = "55555555-5555-5555-5555-555555555555", t2 = "66666666-6666-6666-6666-666666666666"
        let base = [screen(main, 0, 0, 3840, 2160),
                    screen(t1, 200, -900, 1600, 900),
                    screen(t2, 2000, -900, 1600, 900),
                    screen(side, 3840, 0, 1440, 2560, rotation: 90)]
        let swapped = [screen(main, 0, 0, 3840, 2160),
                       screen(t2, 200, -900, 1600, 900),
                       screen(t1, 2000, -900, 1600, 900),
                       screen(side, 3840, 0, 1440, 2560, rotation: 90)]
        // 各自沿边偏移（两块仍不相触）、右屏上移
        let shifted = [screen(main, 0, 0, 3840, 2160),
                       screen(t1, 0, -900, 1600, 900),
                       screen(t2, 2100, -900, 1600, 900),
                       screen(side, 3840, -300, 1440, 2560, rotation: 90)]
        // 上方两块挪到彼此贴合 → 新增邻接对，按 spec §3.1 属另一拓扑
        let touching = [screen(main, 0, 0, 3840, 2160),
                        screen(t1, 200, -900, 1600, 900),
                        screen(t2, 1800, -900, 1600, 900),
                        screen(side, 3840, 0, 1440, 2560, rotation: 90)]
        XCTAssertNotEqual(key(base), key(touching))
        XCTAssertNotEqual(key(base), key(swapped))
        XCTAssertEqual(key(base), key(shifted))
        XCTAssertEqual(key(base), key([base[3], base[1], base[0], base[2]]))
    }

    // MARK: 镜像（spec §3.3）

    func testAnyScreenInMirrorSetMarksTopologyMirrored() {
        XCTAssertFalse(ObservedTopology(screens: home()).isMirrored)
        var mirrored = home()
        mirrored[0] = screen(laptop, -1512, 400, 1512, 982, mirrored: true)
        XCTAssertTrue(ObservedTopology(screens: mirrored).isMirrored)
    }

    // MARK: 展示数据（spec §3.2，不参与身份）

    func testDisplayDataCarriesNameFrameResolutionAndRotation() {
        let observed = ObservedTopology(screens: [
            screen(main, 0, 0, 2560, 1440, name: "DELL U2723QE", pixels: (5120, 2880)),
            screen(laptop, -1512, 400, 1512, 982, name: "内置视网膜显示器", pixels: (3024, 1964)),
        ])
        XCTAssertEqual(observed.displays, [
            TopologyDisplayInfo(uuid: laptop, name: "内置视网膜显示器",
                                frame: SnapshotDisplayFrame(x: -1512, y: 400, w: 1512, h: 982),
                                pixelWidth: 3024, pixelHeight: 1964, rotation: 0),
            TopologyDisplayInfo(uuid: main, name: "DELL U2723QE",
                                frame: SnapshotDisplayFrame(x: 0, y: 0, w: 2560, h: 1440),
                                pixelWidth: 5120, pixelHeight: 2880, rotation: 0),
        ], "按从左到右（再自上而下）排列")
        XCTAssertEqual(observed.identity.displayUUIDs, [laptop, main].sorted())
    }

    func testDisplayNameDoesNotAffectKey() {
        var renamed = home()
        renamed[1] = screen(main, 0, 0, 2560, 1440, name: "Other")
        XCTAssertEqual(key(home()), key(renamed))
    }

    // MARK: 拓扑键格式

    /// 拓扑键可作文件/目录名：仅小写十六进制、定长 32，与屏数和 UUID 长度无关
    func testKeyIsFileNameSafeAndBounded() {
        let many = (0..<8).map { i in
            screen(String(repeating: "\(i)", count: 8) + "-AAAA-BBBB-CCCC-DDDDDDDDDDDD/:", CGFloat(i) * 1920, 0, 1920, 1080)
        }
        for k in [key([screen(laptop, 0, 0, 1512, 982)]), key(home()), key(many)] {
            XCTAssertEqual(k.count, 32)
            XCTAssertTrue(k.allSatisfy { "0123456789abcdef".contains($0) }, k)
        }
    }

    // MARK: Displays.Info 直算（恢复引擎回滚快照键用）

    /// 由活动屏信息 + 旋转直算身份：与同几何/旋转的 TopologyScreen 观测一致；无 UUID 的屏不参与
    func testIdentityFromDisplayInfosMatchesObservedTopology() {
        let infos = [Displays.Info(id: 1, bounds: CGRect(x: -1512, y: 400, width: 1512, height: 982), uuid: laptop),
                     Displays.Info(id: 2, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440), uuid: main),
                     Displays.Info(id: 3, bounds: CGRect(x: 2560, y: -200, width: 1440, height: 2560), uuid: side),
                     Displays.Info(id: 4, bounds: CGRect(x: 0, y: 1440, width: 100, height: 100), uuid: nil)]
        let identity = Displays.topologyIdentity(of: infos, rotation: { $0 == 3 ? 90 : 0 })
        XCTAssertEqual(identity, ObservedTopology(screens: home()).identity)
    }
}
