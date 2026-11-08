import Core
import Foundation

// SnapshotEngine.swift — 一次性拍快照（display-presets 票 03，spec §4.3/§8；取代票 12 的 2s 轮询差分 + 防抖落盘）。
// 只在调用方显式请求时（保存/覆盖预设、调试命令）执行一次：CG 枚举 → 组装（AX 读标题/几何、SLS Space 归属、
// 屏归属口径，见 SnapshotComposer）→ 连同组装起点的观测拓扑一并返回。引擎无 timer、无通知观察、不落盘，
// 存储归调用方（PresetStore）。未就绪/镜像中的门控归调用方（保存流程）；恢复管线独占 SkyLight 时拒绝。

/// 一次拍快照的产物：快照 + 组装起点的观测拓扑（预设存入该拓扑，二者同源同一份显示器读数）
public struct LayoutCapture: Sendable {
    public let snapshot: Snapshot
    public let topology: ObservedTopology

    public init(snapshot: Snapshot, topology: ObservedTopology) {
        self.snapshot = snapshot
        self.topology = topology
    }
}

public enum SnapshotCaptureError: Error, Equatable {
    /// 恢复/撤销管线独占 SkyLight（compose 读 SLS 会与管线并发，实测 11-03 managedSpaces 失败）
    case restoreInProgress
    /// 无活动显示器
    case noActiveDisplay
    /// 采样期间显示器集合/几何变化：内容是拔插中途态，与组装起点拓扑不一致
    case topologyChangedWhileComposing
}

public final class SnapshotEngine: @unchecked Sendable {
    /// 延迟几何：组装时的几何覆盖源（生产 = RestoreEngine.DeferredGeometry）
    private let deferredGeometry: DeferredGeometryPort?
    /// 恢复管线独占期间不拍（compose 读 SLS）
    private let session: SkyLightSession
    private let composer: SnapshotComposer
    private let enumerator: WindowEnumerating
    private let displaysProvider: () -> [Displays.Info]
    private let topologyProvider: ([Displays.Info]) -> ObservedTopology
    private let log: LogWriting?
    private let now: () -> Date

    public init(spaces: SpaceProviding?,
                log: LogWriting? = nil,
                enumerator: WindowEnumerating = CGWindowListEnumerator(),
                ax: WindowAXProbing = MinimalAXReader(),
                displaysProvider: @escaping () -> [Displays.Info] = Displays.active,
                topologyProvider: @escaping ([Displays.Info]) -> ObservedTopology = {
                    ObservedTopology(screens: Displays.topologyScreens($0))
                },
                deferredGeometry: DeferredGeometryPort? = nil,
                session: SkyLightSession = SkyLightSession(),
                now: @escaping () -> Date = Date.init) {
        // compose 与 pending 补写同为 shared 可并发，SLS 读须经 session 串行
        self.composer = SnapshotComposer(spaces: spaces.map(session.serializingReads), ax: ax)
        self.enumerator = enumerator
        self.displaysProvider = displaysProvider
        self.topologyProvider = topologyProvider
        self.log = log
        self.deferredGeometry = deferredGeometry
        self.session = session
        self.now = now
    }

    /// 拍一次快照（同步；SLS/AX 读，插拔中可达数秒，调用方自定线程）
    public func capture() throws -> LayoutCapture {
        guard let result = session.shared({ captureShared() }) else {
            log?.write("[snapshot] action=capture result=skip detail=restore-pipeline-exclusive")
            throw SnapshotCaptureError.restoreInProgress
        }
        return try result.get()
    }

    /// 显示器集合 + 全局几何签名（组装前后比对用）
    static func displaySignature(_ displays: [Displays.Info]) -> [String] {
        displays.map { "\($0.uuid ?? "-")#\($0.bounds.minX),\($0.bounds.minY),\($0.bounds.width)x\($0.bounds.height)" }
            .sorted()
    }

    private func captureShared() -> Result<LayoutCapture, SnapshotCaptureError> {
        let started = Date()
        let displays = displaysProvider()
        guard !displays.isEmpty else {
            log?.write("[snapshot] action=capture result=fail detail=no-active-display")
            return .failure(.noActiveDisplay)
        }
        let topology = topologyProvider(displays)
        let snapshot = composer.compose(sample: enumerator.sample(), displays: displays, capturedAt: now(),
                                        geometryOverrides: deferredGeometry?.geometryOverrides() ?? [:])
        // 采样（SLS/AX，插拔中可达数秒）期间显示器变了 → 内容是拔插中途态，拓扑却是起点：拒绝。
        // 实测 11-03 09:08:16：拔屏开始 2.2s 后的一份组装按起点拓扑落盘，插回时结构门槛 6 轮不过放弃恢复
        guard Self.displaySignature(displaysProvider()) == Self.displaySignature(displays) else {
            log?.write("[snapshot] action=capture topology=\(topology.identity.key) result=skip "
                + "detail=topology-changed-while-composing")
            return .failure(.topologyChangedWhileComposing)
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        log?.write("[snapshot] action=capture topology=\(topology.identity.key) result=ok "
            + "detail=displays=\(displays.count) spaces=\(snapshot.spaces.count) windows=\(snapshot.windows.count) ms=\(ms)")
        return .success(LayoutCapture(snapshot: snapshot, topology: topology))
    }
}
