import Core
import Foundation
import SnapshotEngine
import XCTest
@testable import MenubarKit

// SavePresetFlowTests — 「保存当前布局为预设…」流程（display-presets spec §4.3，票 03）。
// 接缝：SavePresetFlow 公共接口（availability() / run()）；拍快照经注入闭包（fake 快照 + 观测拓扑），
// 输入框经 PresetNamePrompting（fake 按脚本应答），存储用真实 PresetStore（临时目录）。
final class SavePresetFlowTests: XCTestCase {
    /// 输入框假件：按脚本依次应答（nil = 取消），记录每次弹出的默认名与提示
    private final class ScriptedPrompt: PresetNamePrompting {
        var answers: [String?]
        private(set) var asked: [(defaultName: String, message: String?)] = []
        init(_ answers: [String?]) { self.answers = answers }
        func promptPresetName(defaultName: String, message: String?) -> String? {
            asked.append((defaultName, message))
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }

    private var directory: URL!
    private var store: PresetStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("winductor-savepreset-\(UUID().uuidString)", isDirectory: true)
        store = PresetStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 默认名 = 时间「MM-dd HH:mm」；确认后存入拍快照时的拓扑，拓扑首个预设默认自动
    func testSaveWithDefaultNameStoresPresetUnderCapturedTopologyAsAuto() throws {
        let prompt = ScriptedPrompt(["11-08 14:30"])
        let flow = makeFlow(prompt: prompt)

        let outcome = flow.run()

        XCTAssertEqual(prompt.asked.map(\.defaultName), ["11-08 14:30"])
        XCTAssertNil(prompt.asked.first?.message)
        let saved = try XCTUnwrap(store.topology(key: capture.topology.identity.key))
        XCTAssertEqual(saved.presets.map(\.name), ["11-08 14:30"])
        XCTAssertEqual(saved.presets.map(\.isAuto), [true], "拓扑下首个预设默认自动（spec §4.2）")
        XCTAssertEqual(saved.presets.first?.snapshot, capture.snapshot)
        XCTAssertEqual(outcome, .saved(name: "11-08 14:30", topologyKey: capture.topology.identity.key))
    }

    /// 取消：不写任何东西
    func testCancelSavesNothing() {
        let flow = makeFlow(prompt: ScriptedPrompt([nil]))

        XCTAssertEqual(flow.run(), .cancelled)
        XCTAssertEqual(store.topologies(), [])
    }

    /// 撞名：提示改名并预填刚输入的名称，改名后存入；已有预设的拓扑里新预设不自动
    func testDuplicateNameRepromptsUntilUniqueName() throws {
        try store.addPreset(name: "工作", snapshot: capture.snapshot, topology: capture.topology)
        let prompt = ScriptedPrompt([" 工作 ", "工作 2"])
        let flow = makeFlow(prompt: prompt)

        XCTAssertEqual(flow.run(), .saved(name: "工作 2", topologyKey: capture.topology.identity.key))

        XCTAssertEqual(prompt.asked.count, 2)
        XCTAssertEqual(prompt.asked[1].defaultName, " 工作 ")
        XCTAssertEqual(prompt.asked[1].message, "已有名为「工作」的预设，请换一个名称")
        let presets = try XCTUnwrap(store.topology(key: capture.topology.identity.key)).presets
        XCTAssertEqual(presets.map(\.name), ["工作", "工作 2"])
        XCTAssertEqual(presets.map(\.isAuto), [true, false])
    }

    /// 撞名后取消：不写
    func testCancelAfterDuplicatePromptSavesNothing() throws {
        try store.addPreset(name: "工作", snapshot: capture.snapshot, topology: capture.topology)
        let flow = makeFlow(prompt: ScriptedPrompt(["工作", nil]))

        XCTAssertEqual(flow.run(), .cancelled)
        XCTAssertEqual(store.topology(key: capture.topology.identity.key)?.presets.map(\.name), ["工作"])
    }

    /// 空白名：提示后重新输入
    func testBlankNameReprompts() throws {
        let prompt = ScriptedPrompt(["   ", "家"])
        XCTAssertEqual(makeFlow(prompt: prompt).run(), .saved(name: "家", topologyKey: capture.topology.identity.key))
        XCTAssertEqual(prompt.asked.map(\.message), [nil, "名称不能为空"])
    }

    // MARK: 禁用（spec §4.3：未就绪 / 镜像中 / 恢复进行中）

    /// 可用性判定：三种禁用各自成立；全不成立 = 可用
    func testAvailabilityReportsEachDisabledState() {
        let prompt = ScriptedPrompt([])
        XCTAssertEqual(makeFlow(prompt: prompt).availability(), .available)
        XCTAssertEqual(makeFlow(prompt: prompt, isReady: { false }).availability(), .notReady)
        XCTAssertEqual(makeFlow(prompt: prompt, isMirrored: { true }).availability(), .mirrored)
        XCTAssertEqual(makeFlow(prompt: prompt, isRestoring: { true }).availability(), .restoring)
    }

    /// 禁用态下被调用（菜单项本应置灰，防御）：不拍快照、不弹框、不写
    func testRunWhileDisabledDoesNothing() {
        final class Counter { var captures = 0 }
        for (state, flow) in [
            (SavePresetAvailability.notReady, { (p: PresetNamePrompting, c: @escaping () throws -> LayoutCapture) in
                self.makeFlow(prompt: p, isReady: { false }, capture: c) }),
            (.mirrored, { p, c in self.makeFlow(prompt: p, isMirrored: { true }, capture: c) }),
            (.restoring, { p, c in self.makeFlow(prompt: p, isRestoring: { true }, capture: c) }),
        ] {
            let counter = Counter()
            let prompt = ScriptedPrompt(["名"])
            let fixture = capture
            let outcome = flow(prompt, { counter.captures += 1; return fixture }).run()
            XCTAssertEqual(outcome, .unavailable(state))
            XCTAssertEqual(counter.captures, 0, "\(state)：不拍快照")
            XCTAssertTrue(prompt.asked.isEmpty, "\(state)：不弹输入框")
        }
        XCTAssertEqual(store.topologies(), [])
    }

    /// 门判定之后才开始的恢复 / 才出现的镜像（拍快照时发现）：同禁用处理，不弹框
    func testRestoreOrMirrorDiscoveredAtCaptureIsUnavailable() {
        let restoringPrompt = ScriptedPrompt(["名"])
        let restoring = makeFlow(prompt: restoringPrompt, capture: { throw SnapshotCaptureError.restoreInProgress })
        XCTAssertEqual(restoring.run(), .unavailable(.restoring))
        XCTAssertTrue(restoringPrompt.asked.isEmpty)

        let mirroredPrompt = ScriptedPrompt(["名"])
        let mirroredScreen = TopologyScreen(uuid: "AAAA-1111", name: "内置", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                            pixelWidth: 100, pixelHeight: 100, rotation: 0, isMirrored: true)
        let snapshot = capture.snapshot
        let mirrored = makeFlow(prompt: mirroredPrompt, capture: {
            LayoutCapture(snapshot: snapshot, topology: ObservedTopology(screens: [mirroredScreen]))
        })
        XCTAssertEqual(mirrored.run(), .unavailable(.mirrored))
        XCTAssertTrue(mirroredPrompt.asked.isEmpty)
        XCTAssertEqual(store.topologies(), [])
    }

    /// 拍快照失败（采样期间拓扑变化）：通知用户、不弹框、不写
    func testCaptureFailureNotifiesAndSavesNothing() {
        final class Notifier: SystemNotifying {
            var deliveries: [(String, String)] = []
            func deliver(title: String, body: String) { deliveries.append((title, body)) }
        }
        let notifier = Notifier()
        let prompt = ScriptedPrompt(["名"])
        let flow = SavePresetFlow(store: store,
                                  capture: { throw SnapshotCaptureError.topologyChangedWhileComposing },
                                  prompt: prompt, isReady: { true }, isMirrored: { false }, isRestoring: { false },
                                  notifier: notifier)

        guard case .failed = flow.run() else { return XCTFail("应为失败") }
        XCTAssertEqual(notifier.deliveries.map(\.0), ["保存预设失败"])
        XCTAssertEqual(notifier.deliveries.map(\.1), ["拍快照失败：拍快照期间屏幕排列发生变化，请稍后重试"])
        XCTAssertTrue(prompt.asked.isEmpty)
        XCTAssertEqual(store.topologies(), [])
    }
}

// MARK: - 工具

extension SavePresetFlowTests {
    /// 2026-11-08 14:30:59 UTC
    var fixedNow: Date { Date(timeIntervalSince1970: 1_794_148_259) }

    var capture: LayoutCapture {
        let screen = TopologyScreen(uuid: "AAAA-1111", name: "内置", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                    pixelWidth: 3024, pixelHeight: 1964, rotation: 0, isMirrored: false)
        let snapshot = Snapshot(
            capturedAt: fixedNow,
            topology: [TopologyDisplay(uuid: "AAAA-1111", localizedName: "内置",
                                       frame: SnapshotDisplayFrame(x: 0, y: 0, w: 1512, h: 982), orientation: 0)],
            spaces: [SnapshotSpace(displayUUID: "AAAA-1111", index: 1, kind: .user, fullscreenAppBundleID: nil)],
            windows: [])
        return LayoutCapture(snapshot: snapshot, topology: ObservedTopology(screens: [screen]))
    }

    func makeFlow(prompt: PresetNamePrompting,
                  isReady: @escaping () -> Bool = { true },
                  isMirrored: @escaping () -> Bool = { false },
                  isRestoring: @escaping () -> Bool = { false },
                  capture: (() throws -> LayoutCapture)? = nil) -> SavePresetFlow {
        let fixture = self.capture
        return SavePresetFlow(store: store,
                              capture: capture ?? { fixture },
                              prompt: prompt,
                              isReady: isReady,
                              isMirrored: isMirrored,
                              isRestoring: isRestoring,
                              now: { [fixedNow] in fixedNow },
                              timeZone: TimeZone(secondsFromGMT: 0)!)
    }
}
