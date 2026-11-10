// PermissionGuideState.swift — 授权窗的纯状态推导（ui-refactor 票 05，spec §6）。
// 输入 PermissionMonitor.Status + 本次运行中是否出现过未就绪，输出页头文案、两行逐项状态（已授权/未授权）与底部状态条三态；
// 视图（PermissionGuideView）只照此排版，不判断。文案按 §6 逐字（测试以独立字面量锁定）。

public struct PermissionGuideState: Equatable {
    /// 分组列表的一行（一项授权）
    public struct Row: Equatable {
        public let kind: PermissionMonitor.Kind
        /// 名称（13pt semibold）
        public let name: String
        /// 说明
        public let detail: String
        /// 图标块 SF Symbol（辅助功能 `accessibility`、屏幕与系统录音 `record.circle`）
        public let symbolName: String
        public let isGranted: Bool

        /// 第三行灰色路径；已授权不显示
        public var settingsPath: String? {
            isGranted ? nil : "系统设置 › 隐私与安全性 › " + name
        }

        /// 行尾列：未授权 =【打开系统设置】，已授权 = 绿色「✓ 已授权」
        public var showsOpenSettingsButton: Bool { !isGranted }
        public static let openSettingsButtonTitle = "打开系统设置"
        public let grantedText = "已授权"
    }

    /// 底部状态条三态
    public enum Footer: Equatable {
        /// 未齐备：小转圈 + 等待提示
        case waiting
        /// 本次运行中授权齐备（此前未就绪）：绿色对勾 + 齐备标题/重启说明 + 行尾【立即重启】
        /// ——授权要重启应用一次才生效（docs/signing.md §5），首启授权与运行中重确认都走这一态
        case restartRequired
        /// 启动即就绪且运行中从未未就绪（通用页「授权引导…」按需打开）：绿色对勾 + 齐备标题/已可用说明，无需重启
        case alreadyReady

        /// 加粗首行；未齐备无
        public var title: String? {
            switch self {
            case .waiting: nil
            case .restartRequired, .alreadyReady: "两项授权已齐备"
            }
        }

        public var caption: String {
            switch self {
            case .waiting: "授权后这里会自动更新。"
            case .restartRequired: "重启 Winductor 后生效。"
            case .alreadyReady: "Winductor 已可正常保存和恢复布局。"
            }
        }

        /// 两项齐备（绿色对勾）
        public var isReady: Bool { self != .waiting }
        public var showsRestartButton: Bool { self == .restartRequired }
        public var restartButtonTitle: String { "立即重启" }
    }

    public let title = "授权 Winductor"
    public let subtitle = "需要两项系统权限来读取和移动窗口。只在本机使用，不上传任何数据。"
    /// 行序 = 引导顺序（辅助功能 → 屏幕与系统录音）
    public let rows: [Row]
    public let footer: Footer

    /// - Parameters:
    ///   - hasBeenNotReady: 本次运行（进程）中是否出现过未就绪——首启未就绪、或运行中重确认降级（§8.4）。
    ///     出现过则齐备后须重启生效；启动即就绪且从未降级则无需重启
    public init(status: PermissionMonitor.Status, hasBeenNotReady: Bool) {
        // 屏幕录制需重新确认（§8.4）时预检虽通过，仍按未授权呈现（Status.screenCaptureEffectivelyGranted）
        rows = PermissionMonitor.Kind.allCases.map { kind in
            switch kind {
            case .accessibility:
                Row(kind: kind, name: "辅助功能", detail: "读取和设置窗口的位置、大小，以及最小化与全屏。",
                    symbolName: "accessibility", isGranted: status.accessibilityGranted)
            case .screenCapture:
                Row(kind: kind, name: "屏幕与系统录音", detail: "读取各屏幕、各桌面上的窗口列表与标题，不录制画面。",
                    symbolName: "record.circle", isGranted: status.screenCaptureEffectivelyGranted)
            }
        }
        footer = !status.isReady ? .waiting : hasBeenNotReady ? .restartRequired : .alreadyReady
    }

    /// 当前可见的全部文本（显示序；按钮标题除外）——供文案锁定与观察
    public var visibleTexts: [String] {
        var texts = [title, subtitle]
        for row in rows {
            texts += [row.name, row.detail]
            texts.append(row.settingsPath ?? row.grantedText)
        }
        return texts + footerTexts
    }

    /// 底部状态条文本（首行在前）
    public var footerTexts: [String] {
        [footer.title, footer.caption].compactMap { $0 }
    }
}
