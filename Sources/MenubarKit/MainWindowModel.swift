import AppKit
import Combine
import Foundation

// MainWindowModel.swift — 统一主窗口的状态源与动作编排（ui-refactor 票 03，spec §5.1/§5.2/§5.5/§5.6）。
// 视图（MainWindowView）只读 state / general、只调本类方法：
//   侧栏与选中 → MainWindowState（纯推导）；拓扑页内容仍归 PresetManagerModel（选中拓扑同步给它，回落口径一致）；
//   通用页 → 权限现状（PermissionMonitor 推送）+ 菜单同源 WiredMenuContent（勾选态 / 撤销可用性 / 动作闭包，
//     MenuRestoreCoordinator.menuContent()），菜单项保留不删；授权引导… → 注入的打开入口（NotReadyGateCoordinator）。
// 刷新：reload（打开/激活/屏幕变化/外部事件，经 MainWindowController）重读存储、当前拓扑与菜单现状。

public final class MainWindowModel: ObservableObject {
    /// 拓扑页内容（预设管理）的状态源
    public let presets: PresetManagerModel
    @Published public private(set) var state: MainWindowState = .empty
    @Published public private(set) var general: GeneralPageState
    /// 关于页版本号（AppVersion.current）
    public let version: String

    private var requested: MainWindowPage?
    private var permissionStatus: PermissionMonitor.Status
    private let menuContent: () -> WiredMenuContent?
    private let openPermissionGuideAction: () -> Void
    private let presetsFolder: URL
    private let logsFolder: URL
    private var presetsObservation: AnyCancellable?

    /// - Parameters:
    ///   - permissionStatus: 初始权限现状（此后经 updatePermissionStatus 推送）
    ///   - menuContent: 菜单同源内容（生产 = MenuRestoreCoordinator.menuContent()；nil = 未装配，通用页动作无效）
    ///   - openPermissionGuide: 打开授权窗（生产 = NotReadyGateCoordinator.showPermissionGuide）
    ///   - presetsFolder / logsFolder: 数据分区路径说明（与菜单 Finder 入口同一目录）
    public init(presets: PresetManagerModel,
                permissionStatus: PermissionMonitor.Status,
                menuContent: @escaping () -> WiredMenuContent?,
                openPermissionGuide: @escaping () -> Void,
                presetsFolder: URL,
                logsFolder: URL,
                version: String = AppVersion.current()) {
        self.presets = presets
        self.permissionStatus = permissionStatus
        self.menuContent = menuContent
        self.openPermissionGuideAction = openPermissionGuide
        self.presetsFolder = presetsFolder
        self.logsFolder = logsFolder
        self.version = version
        self.general = GeneralPageState.make(status: permissionStatus, loginLaunchChecked: false, canUndo: false,
                                             presetsFolder: presetsFolder, logsFolder: logsFolder)
        // 预设管理状态每次重读（含改名/删除等行内操作后）→ 侧栏跟随；@Published 在赋值前发新值
        presetsObservation = presets.$state.sink { [weak self] fresh in self?.recomputeSidebar(entries: fresh.entries) }
        refreshGeneral()
    }

    // MARK: 刷新与选择

    /// 重读存储、当前拓扑与菜单现状（主线程）
    public func reload() {
        presets.reload()
        refreshGeneral()
    }

    /// 侧栏点选
    public func select(_ page: MainWindowPage) {
        requested = page
        if case .topology(let key) = page {
            presets.selectTopology(key)  // 经 $state 回调重算侧栏
        } else {
            recomputeSidebar(entries: presets.state.entries)
        }
    }

    /// 落到当前拓扑（菜单「管理预设…」入口；无当前拓扑预设也落在其页）
    public func selectCurrentTopology() {
        requested = nil
        presets.selectCurrentTopology()
    }

    /// 权限现状推送（PermissionMonitor 状态变化，主线程）
    public func updatePermissionStatus(_ status: PermissionMonitor.Status) {
        guard status != permissionStatus else { return }
        permissionStatus = status
        refreshGeneral()
        recomputeSidebar(entries: presets.state.entries)
    }

    // MARK: 通用页动作（菜单同源）

    public func openPermissionGuide() {
        openPermissionGuideAction()
    }

    public func toggleLoginLaunch() {
        menuContent()?.onToggleLoginLaunch()
        refreshGeneral()
    }

    /// 撤销上次恢复（不可撤销时无动作；撤销完成后由外部事件刷新）
    public func undoLastRestore() {
        guard let content = menuContent(), content.canUndo else { return }
        content.onUndo()
    }

    public func openPresetsFolder() {
        menuContent()?.onOpenPresetsFolder()
    }

    public func openLogsFolder() {
        menuContent()?.onOpenLogsFolder()
    }

    // MARK: 内部

    private func recomputeSidebar(entries: [TopologyListEntry]) {
        let fresh = MainWindowState.make(entries: entries, requested: requested, isReady: permissionStatus.isReady)
        if fresh != state { state = fresh }
    }

    private func refreshGeneral() {
        let content = menuContent()
        let fresh = GeneralPageState.make(status: permissionStatus,
                                          loginLaunchChecked: content?.loginLaunchChecked ?? false,
                                          canUndo: content?.canUndo ?? false,
                                          presetsFolder: presetsFolder, logsFolder: logsFolder)
        if fresh != general { general = fresh }
    }
}

/// 应用版本号（关于页「版本 {VERSION}」）：.app 内取 Info.plist（make-app.sh 由仓库 VERSION 写入），
/// 否则（swift run / swift test）读源码树 VERSION 文件；取不到为「—」
public enum AppVersion {
    /// 仓库根 VERSION（Sources/MenubarKit/ → 仓库根）
    static let sourceTreeFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("VERSION")

    public static func current(bundle: Bundle = .main) -> String {
        // 只认 .app 的 Info.plist（xctest 宿主的 Bundle.main 也有版本号，那是 Xcode 的）
        if bundle.bundleURL.pathExtension == "app" {
            let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            return short.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        }
        let raw = (try? String(contentsOf: sourceTreeFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
    }
}
