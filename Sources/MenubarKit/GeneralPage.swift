import SwiftUI

// GeneralPage.swift — 主窗口「通用」页（ui-refactor 票 03，spec §5.5）。薄视图：只读 MainWindowModel.general、只调 model 动作
// （与菜单同源：登录时启动 / 撤销上次恢复 / 打开预设文件夹 / 打开日志文件夹；授权引导… 打开授权窗）。
//   系统：辅助功能 ● / 录屏与系统录音 ●（名称按系统版本，macOS 27 起第一项称「设备控制和数据访问」；绿 = 已授权，黄 = 待授权，随 PermissionMonitor 实时）+「授权引导…」；登录时启动 ☐
//   恢复：撤销上次恢复 [撤销]（不可撤销时置灰）
//   数据：预设文件夹 / 日志 [在访达中显示] + 路径说明

struct GeneralPage: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        let general = model.general
        PageScroll {
            SectionHeader(title: "系统")
            SettingRow(caption: general.permissionCaption) {
                permission(general.accessibilityName, granted: general.accessibilityGranted)
                permission(general.screenCaptureName, granted: general.screenCaptureGranted)
                Button("授权引导…", action: model.openPermissionGuide).contentButtonStyle()
            }
            SettingRow(caption: "开机后常驻菜单栏；屏幕排列变化时才能自动恢复。") {
                HStack(spacing: 8) {
                    FieldLabel(text: "登录时启动")
                    Toggle("登录时启动", isOn: Binding(get: { general.loginLaunchChecked },
                                                   set: { _ in model.toggleLoginLaunch() }))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
            }
            SectionDivider()
            SectionHeader(title: "恢复")
            SettingRow(caption: "把窗口放回最近一次恢复之前的位置。") {
                HStack(spacing: 8) {
                    FieldLabel(text: "撤销上次恢复")
                    Button("撤销", action: model.undoLastRestore).contentButtonStyle().disabled(!general.canUndo)
                }
            }
            SectionDivider()
            SectionHeader(title: "数据")
            SettingRow(caption: general.dataCaption) {
                HStack(spacing: 8) {
                    FieldLabel(text: "预设文件夹")
                    Button("在访达中显示", action: model.openPresetsFolder).contentButtonStyle()
                }
                HStack(spacing: 8) {
                    FieldLabel(text: "日志")
                    Button("在访达中显示", action: model.openLogsFolder).contentButtonStyle()
                }
            }
        }
    }

    private func permission(_ name: String, granted: Bool) -> some View {
        HStack(spacing: 6) {
            FieldLabel(text: name)
            StatusDot(color: granted ? .green : .yellow)
                .help(GeneralPageState.permissionDotHelp(granted: granted))
        }
    }
}
