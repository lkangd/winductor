// SnapshotEngine.swift — 快照引擎（票 12 拥有本文件）。
// 职责（spec §7.5/§10.1）：每 2s CGWindowListCopyWindowInfo(.optionAll) 差分（tolerance 0.5s）、
// 有变化防抖 1s 原子落盘（连续变化合并）、应用启退/Space 切换/屏幕事件加速器、
// 每拓扑现势 1 份+滚动历史 4 份、轮询环零 AX 调用、未就绪时只轮询不落盘（门控桩，票 18 接线）、
// Space 归属经 Core/Seams.swift 的 SpaceProviding 接缝获取（票 13 实现）。当前为占位。
public enum SnapshotEngineScaffold {
    public static let note = "ticket 12 owns this module"
}
