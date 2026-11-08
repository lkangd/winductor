import Core
import Foundation
import SnapshotEngine
import XCTest
@testable import MenubarKit

// OverwritePresetFlowTests — 「用当前布局覆盖」（display-presets 票 07，spec §4.2/§4.3；管理窗口与「恢复预设 ▸」共用）。
// 接缝：OverwritePresetFlow 公共接口（run / runAsync）；拍快照经注入闭包（fake 快照 + 观测拓扑），
// 确认框经 PresetOverwriteConfirming（fake 按脚本应答），存储用真实 PresetStore（临时目录）。
final class OverwritePresetFlowTests: XCTestCase {
    private final class ScriptedConfirm: PresetOverwriteConfirming {
        var answers: [Bool]
        private(set) var asked: [String] = []
        init(_ answers: [Bool]) { self.answers = answers }
        func confirmOverwrite(presetName: String) -> Bool {
            asked.append(presetName)
            return answers.isEmpty ? false : answers.removeFirst()
        }
    }

    private final class Notifier: SystemNotifying {
        var deliveries: [(title: String, body: String)] = []
        func deliver(title: String, body: String) { deliveries.append((title, body)) }
    }

    private final class Counter { var captures = 0 }

    private var directory: URL!
    private var store: PresetStore!
    private var clock: Date!
    private var notifier: Notifier!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("winductor-overwrite-\(UUID().uuidString)", isDirectory: true)
        clock = Date(timeIntervalSince1970: 1_794_000_000)
        store = PresetStore(directory: directory, now: { [unowned self] in clock })
        notifier = Notifier()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 确认后：快照换成当前布局、保存时间更新，名称与自动标记保留（spec §4.2）
    func testConfirmedOverwriteReplacesSnapshotKeepingNameAndAuto() throws {
        let work = try store.addPreset(name: "工作", snapshot: snapshot(marker: "old"), topology: topology(["A", "B"]))
        clock = clock.addingTimeInterval(3600)
        let confirm = ScriptedConfirm([true])
        let flow = makeFlow(confirm: confirm, capture: { LayoutCapture(snapshot: self.snapshot(marker: "new"),
                                                                       topology: self.topology(["A", "B"])) })

        let outcome = flow.run(presetID: work.id, topologyKey: key(["A", "B"]))

        XCTAssertEqual(confirm.asked, ["工作"])
        XCTAssertEqual(outcome, .overwritten(name: "工作", topologyKey: key(["A", "B"])))
        let stored = try XCTUnwrap(store.topology(key: key(["A", "B"]))?.presets.first)
        XCTAssertEqual(stored.name, "工作")
        XCTAssertTrue(stored.isAuto)
        XCTAssertEqual(stored.snapshot, snapshot(marker: "new"))
        XCTAssertEqual(stored.savedAt, clock)
    }

    /// 确认框取消：不拍快照、不写
    func testDeclinedConfirmationTouchesNothing() throws {
        let work = try store.addPreset(name: "工作", snapshot: snapshot(marker: "old"), topology: topology(["A"]))
        let counter = Counter()
        let flow = makeFlow(confirm: ScriptedConfirm([false]), capture: {
            counter.captures += 1
            return LayoutCapture(snapshot: self.snapshot(marker: "new"), topology: self.topology(["A"]))
        })

        XCTAssertEqual(flow.run(presetID: work.id, topologyKey: key(["A"])), .cancelled)
        XCTAssertEqual(counter.captures, 0)
        XCTAssertEqual(store.topology(key: key(["A"]))?.presets.first?.snapshot, snapshot(marker: "old"))
    }

    /// 禁用态（未就绪 / 镜像中 / 恢复进行中）：不弹确认、不拍快照
    func testUnavailableSkipsConfirmationAndCapture() throws {
        let work = try store.addPreset(name: "工作", snapshot: snapshot(marker: "old"), topology: topology(["A"]))
        let counter = Counter()
        let confirm = ScriptedConfirm([true])
        let flow = makeFlow(confirm: confirm, availability: { .restoring }, capture: {
            counter.captures += 1
            return LayoutCapture(snapshot: self.snapshot(marker: "new"), topology: self.topology(["A"]))
        })

        XCTAssertEqual(flow.run(presetID: work.id, topologyKey: key(["A"])), .unavailable(.restoring))
        XCTAssertTrue(confirm.asked.isEmpty)
        XCTAssertEqual(counter.captures, 0)
    }

    /// 拍快照时的拓扑 ≠ 预设所属拓扑（仅当前拓扑可覆盖）：不写，通知用户
    func testCaptureUnderAnotherTopologyIsRefused() throws {
        let work = try store.addPreset(name: "工作", snapshot: snapshot(marker: "old"), topology: topology(["A", "B"]))
        let flow = makeFlow(confirm: ScriptedConfirm([true]), capture: {
            LayoutCapture(snapshot: self.snapshot(marker: "new"), topology: self.topology(["A"]))
        })

        XCTAssertEqual(flow.run(presetID: work.id, topologyKey: key(["A", "B"])), .topologyChanged)
        XCTAssertEqual(store.topology(key: key(["A", "B"]))?.presets.first?.snapshot, snapshot(marker: "old"))
        XCTAssertNil(store.topology(key: key(["A"])), "不得写进另一拓扑")
        XCTAssertEqual(notifier.deliveries.map(\.title), ["覆盖预设失败"])
        XCTAssertEqual(notifier.deliveries.map(\.body), ["屏幕排列已变化，只能覆盖当前屏幕排列下的预设"])
    }

    /// 拍快照失败：通知用户、不写
    func testCaptureFailureNotifiesAndWritesNothing() throws {
        let work = try store.addPreset(name: "工作", snapshot: snapshot(marker: "old"), topology: topology(["A"]))
        let flow = makeFlow(confirm: ScriptedConfirm([true]),
                            capture: { throw SnapshotCaptureError.topologyChangedWhileComposing })

        guard case .failed = flow.run(presetID: work.id, topologyKey: key(["A"])) else { return XCTFail("应为失败") }
        XCTAssertEqual(notifier.deliveries.map(\.body), ["拍快照失败：拍快照期间屏幕排列发生变化，请稍后重试"])
        XCTAssertEqual(store.topology(key: key(["A"]))?.presets.first?.snapshot, snapshot(marker: "old"))
    }

    /// 异步路径：确认在调用线程，拍快照经后台执行器，写盘与回调经主线程执行器；进行中不受理第二次
    func testRunAsyncCapturesInBackgroundAndRejectsReentry() throws {
        let work = try store.addPreset(name: "工作", snapshot: snapshot(marker: "old"), topology: topology(["A"]))
        let background = ManualExecutor(), main = ManualExecutor()
        let counter = Counter()
        let confirm = ScriptedConfirm([true, true])
        let flow = makeFlow(confirm: confirm, capture: {
            counter.captures += 1
            return LayoutCapture(snapshot: self.snapshot(marker: "new"), topology: self.topology(["A"]))
        }, background: background, main: main)
        var outcomes: [OverwritePresetOutcome] = []

        XCTAssertTrue(flow.runAsync(presetID: work.id, topologyKey: key(["A"])) { outcomes.append($0) })
        XCTAssertEqual(confirm.asked, ["工作"])
        XCTAssertEqual(counter.captures, 0, "拍快照不在调用线程执行")
        XCTAssertFalse(flow.runAsync(presetID: work.id, topologyKey: key(["A"])) { outcomes.append($0) })

        background.drain()
        XCTAssertEqual(counter.captures, 1)
        XCTAssertTrue(outcomes.isEmpty)
        main.drain()
        XCTAssertEqual(outcomes, [.overwritten(name: "工作", topologyKey: key(["A"]))])
        XCTAssertEqual(store.topology(key: key(["A"]))?.presets.first?.snapshot, snapshot(marker: "new"))
        XCTAssertEqual(confirm.asked.count, 1, "被拒的第二次不弹确认")
    }

    // MARK: 工具

    /// 并排贴合的若干屏（每屏 1000×600）
    private func topology(_ uuids: [String]) -> ObservedTopology {
        ObservedTopology(screens: uuids.enumerated().map { index, uuid in
            TopologyScreen(uuid: uuid, name: "屏 \(uuid)", frame: CGRect(x: index * 1000, y: 0, width: 1000, height: 600),
                           pixelWidth: 2000, pixelHeight: 1200, rotation: 0, isMirrored: false)
        })
    }

    private func key(_ uuids: [String]) -> String { topology(uuids).identity.key }

    /// marker 写进 Space 的全屏应用字段，区分新旧快照
    private func snapshot(marker: String) -> Snapshot {
        Snapshot(capturedAt: Date(timeIntervalSince1970: 1_794_000_000), topology: [],
                 spaces: [SnapshotSpace(displayUUID: "A", index: 1, kind: .user, fullscreenAppBundleID: marker)],
                 windows: [])
    }

    private func makeFlow(confirm: PresetOverwriteConfirming,
                          availability: @escaping () -> LayoutCaptureAvailability = { .available },
                          capture: @escaping () throws -> LayoutCapture,
                          background: ManualExecutor? = nil,
                          main: ManualExecutor? = nil) -> OverwritePresetFlow {
        OverwritePresetFlow(store: store,
                            capture: capture,
                            availability: availability,
                            confirm: confirm,
                            notifier: notifier,
                            captureExecutor: { work in background.map { $0.enqueue(work) } ?? work() },
                            mainExecutor: { work in main.map { $0.enqueue(work) } ?? work() })
    }
}
