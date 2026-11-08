import Core
import Foundation
import XCTest
@testable import SnapshotEngine

// SnapshotEngineTests — 一次性拍快照（display-presets spec §4.3/§8，票 03）：
//   不再后台轮询/差分/防抖落盘；capture() 按调用一次性组装（CG 枚举 + AX + SLS + 屏归属，口径见 SnapshotComposer），
//   连同组装时刻的观测拓扑一并返回，存储归调用方（保存预设 → PresetStore）。
// 接缝：SnapshotEngine.capture() + 注入 fake 枚举/AX/Spaces/拓扑。
final class SnapshotEngineTests: XCTestCase {
    private var log: LogSpy!

    override func setUpWithError() throws {
        log = LogSpy()
    }

    /// 一次调用 = 一次采样 + 组装：窗口进快照、AX 只读离屏候选，拓扑取组装起点的显示器
    func testCaptureComposesSnapshotOnceWithTopologyOfComposedDisplays() throws {
        let ax = FakeAXProber(minimizedIDs: [7])
        let enumerator = FakeEnumerator([sample(id: 1, bundleID: "com.a", title: "front"),
                                         sample(id: 7, bundleID: "com.a", title: "bg", onscreen: false)])
        let engine = makeEngine(enumerator, ax: ax)

        let capture = try engine.capture()

        XCTAssertEqual(enumerator.callCount, 1, "一次性拍：只采样一次")
        XCTAssertEqual(ax.callCount, 1, "AX 只读离屏候选（在屏窗口零 AX）")
        XCTAssertEqual(capture.snapshot.windows.map(\.title), ["bg", "front"])
        XCTAssertEqual(capture.snapshot.windows.map(\.minimized), [true, false])
        XCTAssertEqual(capture.snapshot.windows.map(\.spaceIndex), [1, 1])
        XCTAssertEqual(capture.topology.identity.displayUUIDs, [displayUUID])
        XCTAssertTrue(log.all.contains { $0.contains("[snapshot] action=capture") && $0.contains("result=ok") })
    }

    /// 实测缺陷（11-03 09:08:16）沿用：采样（SLS/AX 可达数秒）期间显示器变了 → 内容是拔插中途态，
    /// 与组装起点拓扑不一致：拒绝本次快照（不得存进起点拓扑的预设）
    func testCaptureFailsWhenTopologyChangesWhileComposing() throws {
        final class Flip: @unchecked Sendable { var calls = 0 }
        let flip = Flip()
        let a = fakeDisplay(displayUUID)
        let b = fakeDisplay("BBBB-2222-2222-2222-222222222222", x: 1000)
        let engine = makeEngine(FakeEnumerator([sample(id: 1, bundleID: "com.a", title: "t")]),
                                displaysProvider: {
                                    flip.calls += 1
                                    return flip.calls == 1 ? [a, b] : [a]  // 起点 2 屏，采样后已拔成 1 屏
                                })
        XCTAssertThrowsError(try engine.capture()) { error in
            XCTAssertEqual(error as? SnapshotCaptureError, .topologyChangedWhileComposing)
        }
        XCTAssertTrue(log.all.contains { $0.contains("detail=topology-changed-while-composing") })
    }

    /// 无活动显示器 → 拒绝
    func testCaptureFailsWithoutActiveDisplay() {
        let engine = makeEngine(FakeEnumerator([]), displaysProvider: { [] })
        XCTAssertThrowsError(try engine.capture()) { error in
            XCTAssertEqual(error as? SnapshotCaptureError, .noActiveDisplay)
        }
    }

    /// 恢复管线独占 SkyLight 期间不采样（compose 读 SLS 会与管线并发）：报「恢复进行中」，独占结束后照常
    func testCaptureRefusedWhileRestorePipelineExclusive() throws {
        let session = SkyLightSession()
        let enumerator = FakeEnumerator([sample(id: 1, bundleID: "com.t", title: "t")])
        let engine = makeEngine(enumerator, session: session)

        try session.exclusive("restore") {
            XCTAssertThrowsError(try engine.capture()) { error in
                XCTAssertEqual(error as? SnapshotCaptureError, .restoreInProgress)
            }
        }
        XCTAssertEqual(enumerator.callCount, 0, "独占期间 enumerator 未被调用")
        XCTAssertEqual(try engine.capture().snapshot.windows.map(\.title), ["t"], "独占结束照常拍")
    }

    /// 待补写窗按延迟几何目标记录（同屏时；见 SnapshotComposer）
    func testCaptureAppliesDeferredGeometryOverrides() throws {
        let deferred = FakeDeferredGeometry()
        deferred.overrides = [1: WindowGeometryOverride(displayUUID: displayUUID, x: 0.5, y: 0.5, w: 0.25, h: 0.25)]
        let engine = makeEngine(FakeEnumerator([sample(id: 1, bundleID: "com.t", title: "t")]),
                                deferredGeometry: deferred)
        let w = try XCTUnwrap(engine.capture().snapshot.windows.first)
        XCTAssertEqual([w.x, w.y, w.w, w.h], [0.5, 0.5, 0.25, 0.25])
    }

    /// 无后台节奏（spec §8 删除后台轮询）：不调用 capture 就没有任何 CG 枚举与日志
    func testNoEnumerationWithoutExplicitCapture() {
        let enumerator = FakeEnumerator([sample(id: 1, bundleID: "com.t", title: "t")])
        let engine = makeEngine(enumerator)
        Thread.sleep(forTimeInterval: 0.2)
        withExtendedLifetime(engine) {
            XCTAssertEqual(enumerator.callCount, 0)
            XCTAssertEqual(log.all, [])
        }
    }

    /// 真实 CGWindowListCopyWindowInfo(.optionAll) 单次采样毫秒级；打印实测值作证据
    func testRealSamplingIsMillisecondLevel() {
        let enumerator = CGWindowListEnumerator()
        _ = enumerator.sample()  // warmup
        var total = 0.0
        let n = 5
        for _ in 0..<n {
            let t0 = DispatchTime.now()
            _ = enumerator.sample()
            total += Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
        }
        let avg = total / Double(n)
        print(String(format: "[验收] 单次采样(.optionAll + 候选过滤) avg = %.2f ms（04 基线 6.7ms）", avg))
        XCTAssertLessThan(avg, 250, "单次采样应毫秒级；250ms 为防 CI 抖动的宽松上限")
    }
}

// MARK: - 工具

extension SnapshotEngineTests {
    var displayUUID: String { "AAAA-1111-1111-1111-111111111111" }

    func makeEngine(_ enumerator: FakeEnumerator, ax: WindowAXProbing = FakeAXProber(),
                    displaysProvider: (() -> [Displays.Info])? = nil,
                    session: SkyLightSession = SkyLightSession(),
                    deferredGeometry: DeferredGeometryPort? = nil) -> SnapshotEngine {
        let display = fakeDisplay(displayUUID)
        return SnapshotEngine(
            spaces: FakeSpaces(
                entries: [SpaceEntry(spaceID: 11, displayUUID: displayUUID, index: 1, kind: 0)],
                byWindow: [1: 11, 7: 11]),
            log: log,
            enumerator: enumerator,
            ax: ax,
            displaysProvider: displaysProvider ?? { [display] },
            topologyProvider: { infos in
                // 测试拓扑：不读真实 CG 显示器（fake 的 display id 可能撞上本机真实屏）
                ObservedTopology(screens: infos.map {
                    TopologyScreen(uuid: $0.uuid ?? "", name: "fake", frame: $0.bounds,
                                   pixelWidth: Int($0.bounds.width), pixelHeight: Int($0.bounds.height),
                                   rotation: 0, isMirrored: false)
                })
            },
            deferredGeometry: deferredGeometry,
            session: session)
    }

    func sample(id: UInt32, bundleID: String, title: String, onscreen: Bool = true) -> CGWindowSample {
        CGWindowSample(windowID: id, pid: 42, bundleID: bundleID, title: title,
                       bounds: CGRect(x: 100, y: 100, width: 400, height: 300),
                       isOnscreen: onscreen)
    }
}
