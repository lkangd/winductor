import AppKit
@testable import Core
import CoreGraphics
import Foundation
@testable import RestoreEngine
import SnapshotEngine
import XCTest

// DeferredGeometryTests — 延迟几何模块（记录 → 覆盖 → 可见即补写）。
// 接缝：DeferredGeometry 公共接口（replacePending / geometryOverrides / tick / windowsBecameVisible / start·stop），
// 注入 FakeBridge（活跃 Space、窗归属）+ FakeGeometry（AX 写）。
final class DeferredGeometryTests: XCTestCase {
    private let entry = PendingGeometryEntry(windowID: 7, displayUUID: "A-uuid", x: 0.1, y: 0.2, w: 0.5, h: 0.4)

    private func makeModule(bridge: FakeBridge, geometry: FakeGeometry = FakeGeometry(),
                            session: SkyLightSession = SkyLightSession()) throws -> DeferredGeometry {
        DeferredGeometry(directory: try makeTempDir(), spaces: bridge, session: session,
                         writer: geometry, displaysProvider: { World.displays() },
                         frameReader: { _ in nil })
    }

    /// 补写前快照按 pending 目标记录（防 macOS 中间态被固化成下次恢复目标，11-03 ghostty/WeCom）
    func testRecordedPendingBecomesSnapshotOverride() throws {
        let module = try makeModule(bridge: FakeBridge(entries: [], byWindow: [:]))
        XCTAssertEqual(module.geometryOverrides(), [:])
        module.replacePending([entry])
        XCTAssertEqual(module.geometryOverrides(),
                       [7: WindowGeometryOverride(displayUUID: "A-uuid", x: 0.1, y: 0.2, w: 0.5, h: 0.4)])
    }

    /// 一轮消费：窗所在 Space 是某屏活跃 Space = 用户看得见 = AX 可写 → 补写并消费；其余保留
    func testTickAppliesOnlyWindowsOnActiveSpaces() throws {
        let bridge = FakeBridge(entries: [], byWindow: [7: 5, 8: 99])
        bridge.activeSpaces = [5]
        let geometry = FakeGeometry()
        let module = try makeModule(bridge: bridge, geometry: geometry)
        let other = PendingGeometryEntry(windowID: 8, displayUUID: "A-uuid", x: 0, y: 0, w: 1, h: 1)
        module.replacePending([entry, other])

        module.tick()

        XCTAssertEqual(geometry.calls, [FakeGeometry.Call(windowID: 7, position: CGPoint(x: 100, y: 200),
                                                          size: CGSize(width: 500, height: 400))])
        XCTAssertEqual(Array(module.geometryOverrides().keys), [8], "已补写的窗不再覆盖快照")
    }

    /// 恢复管线独占期间不消费（管线自己在摆窗，补写会与之争 AX）
    func testTickSkippedWhilePipelineExclusive() throws {
        let bridge = FakeBridge(entries: [], byWindow: [7: 5])
        bridge.activeSpaces = [5]
        let geometry = FakeGeometry(), session = SkyLightSession()
        let module = try makeModule(bridge: bridge, geometry: geometry, session: session)
        module.replacePending([entry])

        session.exclusive("restore") { module.tick() }

        XCTAssertTrue(geometry.calls.isEmpty)
        XCTAssertEqual(Array(module.geometryOverrides().keys), [7])
    }

    /// 可见性迁移（poller 回调）：补写投到模块队列异步执行，不拖住轮询（AX 写 + 回读可达秒级）
    func testWindowsBecameVisibleAppliesAsynchronously() throws {
        let geometry = FakeGeometry()
        geometry.applyDelay = 0.5
        let module = try makeModule(bridge: FakeBridge(entries: [], byWindow: [:]), geometry: geometry)
        module.replacePending([entry])

        let start = Date()
        module.windowsBecameVisible([7])
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2, "调用方（poller）不被 AX 写阻塞")

        let applied = expectation(description: "applied")
        DispatchQueue.global().async {
            while module.geometryOverrides()[7] != nil { Thread.sleep(forTimeInterval: 0.02) }
            applied.fulfill()
        }
        wait(for: [applied], timeout: 3)
        XCTAssertEqual(geometry.calls.map(\.windowID), [7])
    }

    /// 自驱：start 后 Space 切换即补一轮（后台窗正是在用户切过去时才可写，不等下一个 2s tick）；
    /// stop 后断环释放（11-03 实测缺陷：消费器曾因 [weak self] 随装配函数返回被释放，pending 从未消费）
    func testStartedModuleConsumesOnSpaceChangeAndReleasesAfterStop() throws {
        let bridge = FakeBridge(entries: [], byWindow: [7: 5])
        bridge.activeSpaces = [5]
        let geometry = FakeGeometry()
        let center = NotificationCenter()
        weak var weakModule: DeferredGeometry?
        do {
            let module = try makeModule(bridge: bridge, geometry: geometry)
            module.replacePending([entry])
            module.start(interval: 60, center: center)
            weakModule = module
        }
        XCTAssertNotNil(weakModule, "启动后自持存活，直到 stop")

        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        let applied = expectation(description: "applied")
        DispatchQueue.global().async {
            while geometry.calls.isEmpty { Thread.sleep(forTimeInterval: 0.02) }
            applied.fulfill()
        }
        wait(for: [applied], timeout: 3)

        weakModule?.stop()
        let released = expectation(description: "released")
        DispatchQueue.global().async {
            while weakModule != nil { Thread.sleep(forTimeInterval: 0.02) }
            released.fulfill()
        }
        wait(for: [released], timeout: 2)
    }
}
