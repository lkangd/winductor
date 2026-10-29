// swift-tools-version:6.0
// 窗口布局恢复器 WindowLayoutRestorer — SwiftPM 工程骨架（编排者预置，spec §10.1 模块划分）
// target 归属与票对应：
//   Core            ← 票 11（schema/存储/保守匹配/日志；Seams.swift 为编排者冻结的接缝）
//   AXFacade        ← 票 13
//   SpaceAdapter    ← 票 13
//   SnapshotEngine  ← 票 12
//   RestoreEngine   ← 票 14（15/16/17 增量）
//   MenubarKit      ← 票 10（19 全量接线）
//   WindowLayoutRestorer ← 票 10（app 入口）
//   VerifyCLI       ← 票 11 起步，14/15/16 增量
//   DebugCLI        ← 票 13 加 list-spaces/move-window；12 可加 snapshot-now；14 加 restore；16 加 undo
import PackageDescription

let package = Package(
    name: "WindowLayoutRestorer",
    platforms: [.macOS(.v15)],
    targets: [
        // 共享基座：快照 schema、存储原语、保守匹配、结构化日志（app 与 verify 共用同一份，spec §9.1）
        .target(name: "Core"),
        // AX 门面：几何/AXMinimized/AXFullScreen 读写、_AXUIElementGetWindow 配对
        .target(name: "AXFacade", dependencies: ["Core"]),
        // 私有集中层：SLS 枚举、桥接移窗、启动探针、运行时 no-op 识别、FORCE_DEGRADED 钩子
        .target(name: "SpaceAdapter", dependencies: ["Core"]),
        // 快照引擎：2s 轮询差分、1s 防抖原子落盘、每拓扑 1+4 滚动、未就绪门控桩
        .target(name: "SnapshotEngine", dependencies: ["Core", "AXFacade"]),
        // 恢复引擎：触发链、保守匹配恢复管线、回滚快照、撤销
        .target(
            name: "RestoreEngine",
            dependencies: ["Core", "AXFacade", "SpaceAdapter", "SnapshotEngine"]
        ),
        // 菜单栏 UI：状态项三态、菜单七项、首启引导窗、通知
        .target(name: "MenubarKit", dependencies: ["Core", "SnapshotEngine", "RestoreEngine"]),
        // 菜单栏 agent 应用入口（LSUIElement）
        .executableTarget(
            name: "WindowLayoutRestorer",
            dependencies: ["MenubarKit"]
        ),
        // verify CLI（验证器）：独立可执行，与 app 共享 Core 匹配逻辑
        .executableTarget(
            name: "VerifyCLI",
            dependencies: ["Core", "AXFacade", "SpaceAdapter"]
        ),
        // 调试命令面板（演示面/验收驱动）
        .executableTarget(
            name: "DebugCLI",
            dependencies: ["Core", "AXFacade", "SpaceAdapter", "SnapshotEngine", "RestoreEngine"]
        ),
        // 票 10 新增（唯一例外场景）：占位菜单骨架的结构测试（spec §8.2），票 19 接线后可扩三态图标测试
        .testTarget(name: "MenubarKitTests", dependencies: ["MenubarKit"]),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
        .testTarget(name: "SnapshotEngineTests", dependencies: ["SnapshotEngine", "Core"]),
        .testTarget(name: "RestoreEngineTests", dependencies: ["RestoreEngine", "Core"]),
    ],
    // 语言模式锁 5：CGWindowList/AX/SLS 全局函数与闭包在 mode 6 严格并发下摩擦大，无收益
    swiftLanguageModes: [.v5]
)
