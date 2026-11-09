import Core
import Foundation
import SnapshotEngine

// LayoutCaptureSupport.swift — 「保存当前布局为预设…」与「用当前布局覆盖」共用的拍快照部件
// （display-presets 票 03/07 评审修复：两条流程原各有一份）。
// 可用性三态、一次性拍快照装配（本应用自身窗口不入快照）、拍快照结果的不可用判定、两段执行器 + 在途守卫。

/// 拍快照入口（保存 / 覆盖）可用性（spec §4.3 禁用三态；两入口同口径）
public enum LayoutCaptureAvailability: Equatable {
    case available
    /// 两项授权未齐（未就绪门控）
    case notReady
    /// 任一屏处于镜像集合（spec §3.3）
    case mirrored
    /// 恢复/撤销管线进行中
    case restoring
}

/// 一次拍快照的判定：拿到可写的布局，或流程已有定论
enum LayoutCaptureCheck {
    case captured(LayoutCapture)
    /// 门后才发现的恢复进行中 / 镜像中（入口本应置灰，防御）
    case unavailable(LayoutCaptureAvailability)
    /// 拍快照失败（用户文案）
    case failed(String)

    /// - action: 日志 action= 字段（save / overwrite）
    static func check(_ result: Result<LayoutCapture, Error>, action: String, log: LogWriting?) -> LayoutCaptureCheck {
        switch result {
        case .failure(SnapshotCaptureError.restoreInProgress):
            log?.write("[preset] action=\(action) result=skip detail=unavailable=restoring")
            return .unavailable(.restoring)
        case .failure(let error):
            return .failed("拍快照失败：\(describe(error))")
        case .success(let captured) where captured.topology.isMirrored:
            log?.write("[preset] action=\(action) result=skip detail=unavailable=mirrored")
            return .unavailable(.mirrored)
        case .success(let captured):
            return .captured(captured)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error as? SnapshotCaptureError {
        case .noActiveDisplay?: return "无活动显示器"
        case .topologyChangedWhileComposing?: return "拍快照期间屏幕排列发生变化，请稍后重试"
        case .restoreInProgress?: return "恢复进行中"
        case nil: return String(describing: error)
        }
    }
}

/// 两段执行器 + 单轮在途守卫：拍快照经 captureExecutor 离开主线程（SLS/AX 读，遇无响应应用可达数秒），
/// 后续（输入框 / 写盘）与 completion 经 mainExecutor 回到主线程。只在主线程调用。
final class CaptureRound {
    private let captureExecutor: (@escaping () -> Void) -> Void
    private let mainExecutor: (@escaping () -> Void) -> Void
    /// 一轮进行中（受理 → 拍快照 → 后续处理）；只在主线程读写
    private var isRunning = false

    init(captureExecutor: @escaping (@escaping () -> Void) -> Void,
         mainExecutor: @escaping (@escaping () -> Void) -> Void) {
        self.captureExecutor = captureExecutor
        self.mainExecutor = mainExecutor
    }

    /// 受理新一轮；上一轮未结束返回 false（调用方记 in-flight 日志、不回调）
    func begin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    /// 未进入拍快照即有定论（门 / 确认框取消）：结束本轮
    func end() {
        isRunning = false
    }

    /// 拍快照离主线程，结果回主线程交 process（仍在本轮内：输入框开着时不受理新一轮），
    /// 之后结束本轮再回调 completion
    func capture<Outcome>(_ capture: @escaping () -> Result<LayoutCapture, Error>,
                          process: @escaping (Result<LayoutCapture, Error>) -> Outcome,
                          completion: @escaping (Outcome) -> Void) {
        captureExecutor { [self] in
            let captured = capture()
            mainExecutor { [self] in
                let outcome = process(captured)
                isRunning = false
                completion(outcome)
            }
        }
    }
}

extension RuntimeAssembly {
    /// 保存与覆盖共用的一次性拍快照：SnapshotEngine（spaces 注入 Space 归属；与恢复管线同一 session 独占、
    /// 同一延迟几何覆盖），本应用自身窗口（开着的主窗口等）不入快照
    static func makeLayoutCapture(spaces: SpaceProviding?,
                                  session: SkyLightSession,
                                  deferredGeometry: DeferredGeometryPort?,
                                  log: LogWriting?) -> () throws -> LayoutCapture {
        let engine = SnapshotEngine(spaces: spaces, log: log, deferredGeometry: deferredGeometry, session: session)
        return layoutCapture(excludingWindowsOf: Bundle.main.bundleIdentifier) { try engine.capture() }
    }

    /// 包一层拍快照：去掉 ownBundleID 的窗口（nil = 不过滤），拓扑原样
    static func layoutCapture(excludingWindowsOf ownBundleID: String?,
                              _ capture: @escaping () throws -> LayoutCapture) -> () throws -> LayoutCapture {
        guard let ownBundleID else { return capture }
        return {
            let captured = try capture()
            var snapshot = captured.snapshot
            snapshot.windows.removeAll { $0.bundleID == ownBundleID }
            return LayoutCapture(snapshot: snapshot, topology: captured.topology)
        }
    }
}
