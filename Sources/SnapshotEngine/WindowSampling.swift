import Core
import CoreGraphics
import Foundation

// WindowSampling.swift — 轮询环差分指纹（spec §7.5）。
// 采样本身（CGWindowSample / WindowEnumerating / CGWindowListEnumerator）在 Core/WindowSampling.swift，
// 与恢复引擎、VerifyCLI 共用同一过滤口径。

/// 差分指纹 = 拓扑（UUID + bounds + 旋转）+ 候选窗口集合（按 windowID 排序）。
/// 指纹相等 ⇔ 无变化不写盘（spec §7.5）；拓扑入指纹使屏幕事件（分辨率/插拔）必被检出。
public struct WindowFingerprint: Equatable, Sendable {
    struct DisplayMark: Equatable, Sendable {
        let uuid: String
        let bounds: CGRect
        let orientation: Int
    }
    let topology: [DisplayMark]
    let windows: [CGWindowSample]

    public init(displays: [Displays.Info], windows: [CGWindowSample]) {
        self.topology = displays.map {
            DisplayMark(uuid: $0.uuid ?? "", bounds: $0.bounds, orientation: Displays.rotation(for: $0.id))
        }
        self.windows = windows.sorted { $0.windowID < $1.windowID }
    }
}
