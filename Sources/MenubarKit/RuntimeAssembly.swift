import Core
import Foundation
import SnapshotEngine

// RuntimeAssembly.swift — 票 18 装配件：带就绪门的快照引擎（spec §4.6/§8.3）。
// app 入口经此组装引擎：readinessGate = { monitor.isReady }（未就绪 = 引擎照常轮询但
// 零落盘，票 12 已实现并锁定该语义）。放 MenubarKit 是因为 app 入口 target 只依赖
// MenubarKit（Package.swift 禁改，不能直 import SnapshotEngine）。
// SpaceAdapter 归属注入（SpaceProviding）归票 17/19 全量接线。

public enum RuntimeAssembly {
    /// 组装就绪门接线的快照引擎。storeDirectory 可注入（单测用临时目录；生产默认用户目录）。
    public static func makeSnapshotEngine(gatedBy monitor: PermissionMonitor,
                                          storeDirectory: URL = SnapshotStore.defaultDirectory,
                                          log: LogWriting? = nil) -> SnapshotEngine {
        let engine = SnapshotEngine(
            store: SnapshotStore(directory: storeDirectory, log: log),
            spaces: nil,  // Space 归属（SpaceProviding）票 17/19 接线；nil = 降级 spaceIndex
            log: log
        )
        engine.readinessGate = { [monitor] in monitor.status.isReady }
        return engine
    }
}
