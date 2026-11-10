import Foundation
import XCTest
@testable import MenubarKit

// ui-refactor 票 09：系统设置两项授权面板的界面名按 macOS 版本取（授权窗名称 / 灰色路径行、通用页状态行同源）。
// 接缝：SystemSettingsPaneNames.forSystem(_:) —— 纯函数，系统版本可注入。
// 独立事实来源（测试自带字面量）：
//   - macOS 27：本机 /System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex 的 zh_CN 本地化
//     （Localizable.loctable ACCESSIBILITY =「设备控制和数据访问」、SCREENANDAUDIOCAPTURE =「录屏与系统录音」；
//       InfoPlist.loctable CFBundleDisplayName =「隐私与安全」）
//   - macOS 15 / 26：Apple 中文使用手册（mh43185「系统设置 > 隐私与安全性 > 辅助功能」、
//     mchld6aa7d23「系统设置 > 隐私与安全性 > 录屏与系统录音」）
final class SystemSettingsPaneNamesTests: XCTestCase {
    private func names(_ major: Int, _ minor: Int = 0) -> SystemSettingsPaneNames {
        .forSystem(OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0))
    }

    /// macOS 15 / 26：隐私与安全性 › 辅助功能 / 录屏与系统录音
    func testBeforeMacOS27UsesAccessibilityNaming() {
        for version in [names(15), names(15, 6), names(26), names(26, 4)] {
            XCTAssertEqual(version.name(of: .accessibility), "辅助功能")
            XCTAssertEqual(version.name(of: .screenCapture), "录屏与系统录音")
            XCTAssertEqual(version.settingsPath(of: .accessibility), "系统设置 › 隐私与安全性 › 辅助功能")
            XCTAssertEqual(version.settingsPath(of: .screenCapture), "系统设置 › 隐私与安全性 › 录屏与系统录音")
        }
    }

    /// macOS 27 起：隐私与安全 › 设备控制和数据访问 / 录屏与系统录音
    func testMacOS27UsesDeviceControlNaming() {
        for version in [names(27), names(27, 2), names(28)] {
            XCTAssertEqual(version.name(of: .accessibility), "设备控制和数据访问")
            XCTAssertEqual(version.name(of: .screenCapture), "录屏与系统录音")
            XCTAssertEqual(version.settingsPath(of: .accessibility), "系统设置 › 隐私与安全 › 设备控制和数据访问")
            XCTAssertEqual(version.settingsPath(of: .screenCapture), "系统设置 › 隐私与安全 › 录屏与系统录音")
        }
    }

    /// 当前系统 = 按本机版本取
    func testCurrentFollowsRunningSystem() {
        XCTAssertEqual(SystemSettingsPaneNames.current, .forSystem(ProcessInfo.processInfo.operatingSystemVersion))
    }
}
