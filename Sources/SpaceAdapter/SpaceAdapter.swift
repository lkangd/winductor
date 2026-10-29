// SpaceAdapter.swift — 私有集中层（票 13 拥有本文件）。
// 职责（spec §10.1/§10.2）：SLSCopyManagedDisplaySpaces 枚举、SLSCopySpacesForWindows 窗口→Space、
// SLSBridgedMoveWindowsToManagedSpaceOperation 桥接移窗（教科书写法是静默 no-op，禁止使用）、
// SpaceProviding 实现（见 Core/Seams.swift 冻结接缝）、启动探针、运行时 no-op 识别、
// LAYOUTFIXER_FORCE_DEGRADED=bridge|fullscreen|minimized 层粒度钩子。当前为占位。
public enum SpaceAdapterScaffold {
    public static let note = "ticket 13 owns this module"
}
