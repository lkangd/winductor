import AppKit
import XCTest
@testable import MenubarKit
import RestoreEngine

// RestorePopoverRenderHarness — popover 内容视图的离屏渲染（人工核对视觉对齐用，display-presets 票 14）。
// 默认跳过；设环境变量 WINDUCTOR_POPOVER_RENDER_DIR=<目录> 时把各情形渲染为 PNG（文件名前缀取 WINDUCTOR_POPOVER_RENDER_PREFIX，默认 popover-）。
// 例：WINDUCTOR_POPOVER_RENDER_DIR=/tmp swift test --filter RestorePopoverRenderHarness
final class RestorePopoverRenderHarness: XCTestCase {
    private func notice(_ outcome: AutoRestoredOutcome) -> AutoRestoreNoticeView {
        AutoRestoreNoticeView(content: AutoRestoreNoticeContent.make(outcome)) { _ in }
    }

    private func outcome(ok: Int, skip: Int = 0, fail: Int = 0, degraded: [String] = [], failure: String? = nil,
                         hasOtherPresets: Bool) -> AutoRestoredOutcome {
        AutoRestoredOutcome(topologyKey: "k", presetID: "p1", presetName: "工作",
                            notice: RestoreCompletionNotice(trigger: .auto, okCount: ok, skipCount: skip,
                                                            failCount: fail, degradedLayerNames: degraded,
                                                            failureDetail: failure),
                            hasOtherPresets: hasOtherPresets)
    }

    private func option(_ id: String, _ name: String, summary: [String], shortage: [String] = []) -> RestorePromptOption {
        RestorePromptOption(presetID: id, name: name, summaryLines: summary, shortageLines: shortage)
    }

    func testRenderPopoverCases() throws {
        guard let dir = ProcessInfo.processInfo.environment["WINDUCTOR_POPOVER_RENDER_DIR"] else {
            throw XCTSkip("未设 WINDUCTOR_POPOVER_RENDER_DIR：跳过离屏渲染")
        }
        let prefix = ProcessInfo.processInfo.environment["WINDUCTOR_POPOVER_RENDER_PREFIX"] ?? "popover-"
        let cases: [(String, NSView)] = [
            ("notice-success", notice(outcome(ok: 12, hasOtherPresets: true))),
            ("notice-skip-degrade", notice(outcome(ok: 9, skip: 2, fail: 1, degraded: ["Space 归属", "最小化窗口归位"],
                                                   hasOtherPresets: true))),
            ("notice-no-other", notice(outcome(ok: 12, hasOtherPresets: false))),
            ("notice-failed", notice(outcome(ok: 0, failure: "无活动显示器", hasOtherPresets: true))),
            ("prompt-multi", RestorePromptView(content: RestorePromptContent(
                topologyKey: "k", title: "内置 + DELL U2723QE ×2",
                options: [option("p1", "工作", summary: ["内置：2 个应用 · 3 个窗口", "DELL U2723QE #1：5 个应用 · 9 个窗口"]),
                          option("p2", "演示", summary: ["内置：无窗口", "DELL U2723QE #1：1 个应用 · 1 个窗口"],
                                 shortage: ["屏幕「DELL U2723QE #1」当前 Space 比预设少 1 个，多出的窗口将合并"])],
                selectedPresetID: "p2")) { _ in }),
            ("prompt-single", RestorePromptView(content: RestorePromptContent(
                topologyKey: "k", title: "家里",
                options: [option("p1", "工作", summary: ["DELL：2 个应用 · 3 个窗口"])],
                selectedPresetID: "p1")) { _ in }),
        ]
        for (name, view) in cases {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)\(name).png")
            try png(of: view).write(to: url)
        }
    }

    /// 以 popover 底色衬底、2x 渲染（离屏无 vibrancy，底色近似原生 popover）
    private func png(of content: NSView) throws -> Data {
        let appearance = NSAppearance(named: .aqua)!
        content.appearance = appearance
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.appearance = appearance
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(white: 0.93, alpha: 1).cgColor
        content.frame = host.bounds
        host.addSubview(content)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                   pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
