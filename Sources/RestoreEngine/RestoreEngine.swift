// RestoreEngine.swift — 恢复引擎（票 14/15/16/17 拥有本模块）。
// 职责（spec §6/§8.6）：触发链（17）、保守匹配恢复管线 L1+L2（14）、L3 全屏 + L4 最小化（15）、
// 回滚快照与两段式撤销（16）。一次性恢复，放完即停。当前为占位。
public enum RestoreEngineScaffold {
    public static let note = "tickets 14/15/16/17 own this module"
}
