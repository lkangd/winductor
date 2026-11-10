import Foundation

// SystemSettingsPaneNames.swift — 系统设置里两项授权面板的界面名（简体中文），按 macOS 版本取（ui-refactor 票 09）。
// 授权窗的名称 / 灰色路径行与通用页状态行同源于此；深链不随版本变（见 SystemSettingsOpener）。
// 核实来源：
//   - macOS 27：/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex/Contents/Resources 的 zh_CN 本地化——
//     Localizable.loctable「ACCESSIBILITY」=「设备控制和数据访问」（en: Device Control and Data Access）、
//     「SCREENANDAUDIOCAPTURE」=「录屏与系统录音」；InfoPlist.loctable「CFBundleDisplayName」=「隐私与安全」。
//   - macOS 15 / 26：Apple 中文使用手册——「系统设置 > 隐私与安全性 > 辅助功能」（mh43185）、
//     「系统设置 > 隐私与安全性 > 录屏与系统录音」（mchld6aa7d23）。
// 27.0 / 27.1 本机无从核实，按大版本 27 一刀切。

public struct SystemSettingsPaneNames: Equatable {
    /// 「隐私与安全性」分区名
    public let privacySection: String
    /// 管 AX 信任（AXIsProcessTrusted）的面板：辅助功能 / 设备控制和数据访问
    public let accessibility: String
    /// 管屏幕录制的面板
    public let screenCapture: String

    /// 按系统版本取面板名：macOS 27 起第一项改称「设备控制和数据访问」、分区改称「隐私与安全」
    public static func forSystem(_ version: OperatingSystemVersion) -> SystemSettingsPaneNames {
        if version.majorVersion >= 27 {
            return SystemSettingsPaneNames(privacySection: "隐私与安全", accessibility: "设备控制和数据访问",
                                           screenCapture: "录屏与系统录音")
        }
        return SystemSettingsPaneNames(privacySection: "隐私与安全性", accessibility: "辅助功能",
                                       screenCapture: "录屏与系统录音")
    }

    /// 本机系统版本对应的面板名
    public static var current: SystemSettingsPaneNames {
        forSystem(ProcessInfo.processInfo.operatingSystemVersion)
    }

    /// 某项授权的面板名
    public func name(of kind: PermissionMonitor.Kind) -> String {
        switch kind {
        case .accessibility: accessibility
        case .screenCapture: screenCapture
        }
    }

    /// 授权窗灰色路径行「系统设置 › 隐私与安全性 › …」
    public func settingsPath(of kind: PermissionMonitor.Kind) -> String {
        "系统设置 › \(privacySection) › \(name(of: kind))"
    }
}
