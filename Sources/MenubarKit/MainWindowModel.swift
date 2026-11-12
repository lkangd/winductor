import AppKit
import Combine
import Core
import Foundation

// MainWindowModel.swift — 统一主窗口的状态源与动作编排（ui-refactor 票 03，spec §5.1/§5.2/§5.5/§5.6）。
// 视图（MainWindowView）只读 state / general、只调本类方法：
//   侧栏与选中 → MainWindowState（纯推导）；拓扑页内容仍归 PresetManagerModel（选中拓扑同步给它，回落口径一致）；
//   通用页 → 权限现状（PermissionMonitor 推送）+ 共享 LastRestoreUndo；登录项与目录动作由本 module 持有，
//     不再读取整份菜单内容；授权引导… → 注入的打开入口（NotReadyGateCoordinator）。
// 刷新：reload（打开/激活/屏幕变化/外部事件，经 MainWindowController）重读存储、当前拓扑与通用页现状。

public final class MainWindowModel: ObservableObject {
    /// 拓扑页内容（预设管理）的状态源
    public let presets: PresetManagerModel
    @Published public private(set) var state: MainWindowState = .empty
    @Published public private(set) var general: GeneralPageState
    /// 关于页版本号（AppVersion.current）
    public let version: String

    private var requested: MainWindowPage?
    private var permissionStatus: PermissionMonitor.Status
    private let undo: LastRestoreUndo
    private let loginItem: LoginItemServicing
    private let openFolder: (URL) -> Void
    private let refreshPresentations: () -> Void
    private let log: LogWriting?
    private let openPermissionGuideAction: () -> Void
    private let presetsFolder: URL
    private let logsFolder: URL
    private var presetsObservation: AnyCancellable?

    /// - Parameters:
    ///   - permissionStatus: 初始权限现状（此后经 updatePermissionStatus 推送）
    ///   - undo: 菜单 / 通用页 / 恢复告知共用的撤销 module
    ///   - refreshPresentations: 登录项切换后刷新菜单与可见主窗口（无论成功或失败）
    ///   - openPermissionGuide: 打开授权窗（生产 = NotReadyGateCoordinator.showPermissionGuide）
    ///   - presetsFolder / logsFolder: 数据分区路径说明（共享 Finder 动作的目标目录）
    public init(presets: PresetManagerModel,
                permissionStatus: PermissionMonitor.Status,
                undo: LastRestoreUndo,
                loginItem: LoginItemServicing,
                openPermissionGuide: @escaping () -> Void,
                presetsFolder: URL,
                logsFolder: URL,
                openFolder: @escaping (URL) -> Void = { FinderFolderOpener.open($0) },
                refreshPresentations: @escaping () -> Void,
                log: LogWriting? = nil,
                version: String = AppVersion.current()) {
        self.presets = presets
        self.permissionStatus = permissionStatus
        self.undo = undo
        self.loginItem = loginItem
        self.openFolder = openFolder
        self.refreshPresentations = refreshPresentations
        self.log = log
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

    /// 重读存储、当前拓扑与通用页现状（主线程）
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
        // 权限改变时同步保存/恢复/覆盖按钮；保留原选中页与排列。
        presets.reload()
        refreshGeneral()
        recomputeSidebar(entries: presets.state.entries)
    }

    // MARK: 通用页动作

    public func openPermissionGuide() {
        openPermissionGuideAction()
    }

    public func toggleLoginLaunch() {
        do {
            if loginItem.isEnabled { try loginItem.disable() } else { try loginItem.enable() }
        } catch {
            log?.write("[login-item] toggle failed error=\(String(describing: error))")
        }
        refreshPresentations()
        refreshGeneral()
    }

    /// 撤销上次恢复（不可撤销时无动作；撤销完成后由外部事件刷新）
    public func undoLastRestore() {
        undo.requestIfAvailable()
    }

    public func openPresetsFolder() {
        openFolder(presetsFolder)
    }

    public func openLogsFolder() {
        openFolder(logsFolder)
    }

    // MARK: 内部

    private func recomputeSidebar(entries: [TopologyListEntry]) {
        let fresh = MainWindowState.make(entries: entries, requested: requested, isReady: permissionStatus.isReady)
        if fresh != state { state = fresh }
    }

    private func refreshGeneral() {
        let fresh = GeneralPageState.make(status: permissionStatus,
                                          loginLaunchChecked: loginItem.isEnabled,
                                          canUndo: undo.isAvailable(),
                                          presetsFolder: presetsFolder, logsFolder: logsFolder)
        if fresh != general { general = fresh }
    }
}

/// 应用版本号（关于页「版本 {VERSION}」）：.app 内取 Info.plist（make-app.sh 由仓库 VERSION 写入），
/// 否则（swift run / swift test）读源码树 VERSION 文件；取不到为「—」
public enum AppVersion {
    /// 仓库根 VERSION
    static let sourceTreeFile = RuntimeBundle.sourceTreeRoot.appendingPathComponent("VERSION")

    public static func current(bundle: Bundle = .main) -> String {
        // 只认 .app 的 Info.plist（xctest 宿主的 Bundle.main 也有版本号，那是 Xcode 的）
        if RuntimeBundle.isApp(bundle) {
            let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            return short.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        }
        let raw = (try? String(contentsOf: sourceTreeFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
    }
}
