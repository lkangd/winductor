import Combine
import Core
import Foundation

// PresetManagerModel.swift — 主窗口拓扑页的操作与状态源（display-presets 票 07 起；ui-refactor spec §5.4）。
// 视图（主窗口拓扑页 TopologyPage）只读 state、只调本类方法；规则全在存储（§4.1/§4.2：同拓扑唯一名、自动互斥、
// 删自动不转移）与 PresetManagerState（排序/高亮/逐行可用性），本类只做「对话框 → 存储 → 重读」编排：
//   改名 / 改别名 → 输入框（撞名/空名提示后重弹）→ PresetStore.renamePreset / setAlias；
//   删除 → 确认框 → deletePreset；自动开关 → setAuto；
//   恢复 → 注入的 restore（生产 = MenuRestoreCoordinator.restorePreset，与菜单同一管线）；
//   用当前布局覆盖 → OverwritePresetFlow（与菜单「保存预设 ▸」同一流程）；
//   拓扑页 `⋯` 菜单（ui-refactor 票 04）→ perform(_:presetID:) 分派到覆盖 / 改名 / 删除；
//   保存当前布局… → 注入的 save（生产 = MenuRestoreCoordinator.saveCurrentLayout，与菜单同一流程）。
// 存储无变更通知：每次操作后、窗口激活时、拓扑变化时 reload 重读（拓扑实时刷新）。
// 选择：未手动选拓扑时跟随当前拓扑；手动选过则保留（该拓扑消失时回落）。

/// 拓扑页的对话框接缝（生产：AlertPresetManagerDialogs；测试：脚本假件）
public protocol PresetManagerDialogs: AnyObject {
    /// 改名输入框：预填 currentName；message = 上次输入的问题（首次 nil）。返回 nil = 取消
    func promptRename(currentName: String, message: String?) -> String?
    /// 别名输入框：预填 currentAlias（nil = 未设），placeholder = 默认屏名组合。返回 nil = 取消，空白 = 清除别名
    func promptAlias(currentAlias: String?, placeholder: String) -> String?
    /// 删除确认框。返回 true = 删除
    func confirmDelete(presetName: String) -> Bool
    /// 操作失败提示
    func showError(_ message: String)
}

public final class PresetManagerModel: ObservableObject {
    @Published public private(set) var state: PresetManagerState = .empty
    /// 选中拓扑的存储记录（含预设快照；当前拓扑尚无预设时为 nil）。display-presets 票 08 预设详情据此展开「屏幕 → Space → 应用」
    public private(set) var selectedTopologyRecord: PresetTopology?
    /// 各展开预设块的详情（display-presets 票 08：屏 → Space → 应用，随点屏筛选；键 = 预设 ID）。
    /// 详情默认展开（ui-refactor 票 10），收起的块不推导
    @Published public private(set) var expandedDetails: [String: PresetDetail] = [:]

    private let store: PresetStore
    private let topologyProvider: () -> ObservedTopology
    private let overwriteFlow: OverwritePresetFlow
    private let restoreAction: (_ presetID: String, _ topologyKey: String) -> Void
    private let saveAction: () -> Void
    private let dialogs: PresetManagerDialogs
    private let currentSpaces: () -> [SpaceEntry]?
    private let appName: (String) -> String?
    private let timeZone: TimeZone

    /// 用户手动选中的拓扑（nil = 跟随当前拓扑）
    private var manualSelectedKey: String?
    private var selectedDisplayUUID: String?
    /// 用户收起详情的预设（切换拓扑清空 = 重新全部展开）
    private var collapsedPresetIDs: Set<String> = []

    /// - Parameters:
    ///   - topologyProvider: 当前观测拓扑（生产 = ObservedTopology.current）
    ///   - overwrite: 覆盖流程；其 availability() 同时作恢复/覆盖按钮的可用性门（与保存同口径）
    ///   - restore: 手动恢复（生产 = MenuRestoreCoordinator.restorePreset(id:topologyKey:)）
    ///   - save: 「保存当前布局…」（生产 = MenuRestoreCoordinator.saveCurrentLayout；保存完成经外部事件 reloadIfVisible 刷新）
    ///   - currentSpaces: 实时受管 Space 清单（预设块的 Space 不足提示用；nil = 读不到，不提示）。
    ///     仅选中当前拓扑且有预设时每次重读读一次
    ///   - appName: bundleID → 应用名（生产 = ApplicationNames.localizedName；nil = 回退 bundleID）
    public init(store: PresetStore,
                topologyProvider: @escaping () -> ObservedTopology = ObservedTopology.current,
                overwrite: OverwritePresetFlow,
                restore: @escaping (_ presetID: String, _ topologyKey: String) -> Void,
                save: @escaping () -> Void = {},
                dialogs: PresetManagerDialogs,
                currentSpaces: @escaping () -> [SpaceEntry]? = { nil },
                appName: @escaping (String) -> String? = { _ in nil },
                timeZone: TimeZone = .current) {
        self.store = store
        self.topologyProvider = topologyProvider
        self.overwriteFlow = overwrite
        self.restoreAction = restore
        self.saveAction = save
        self.dialogs = dialogs
        self.currentSpaces = currentSpaces
        self.appName = appName
        self.timeZone = timeZone
        reload()
    }

    // MARK: 刷新与选择

    /// 重读存储与当前拓扑
    public func reload() {
        let topologies = store.topologies()
        let current = topologyProvider()
        let availability = overwriteFlow.availability()
        let make = { (spaces: [SpaceEntry]?) in
            PresetManagerState.make(topologies: topologies, current: current, availability: availability,
                                    selectedKey: self.manualSelectedKey,
                                    selectedDisplayUUID: self.selectedDisplayUUID,
                                    collapsedPresetIDs: self.collapsedPresetIDs,
                                    currentSpaces: spaces, timeZone: self.timeZone)
        }
        var fresh = make(nil)
        // 实时 Space 只在选中当前拓扑且有预设时读（SLS 读；非当前拓扑的 Space 不足无意义）
        if let selected = fresh.selected, selected.isCurrent, !selected.rows.isEmpty, let spaces = currentSpaces() {
            fresh = make(spaces)
        }
        selectedDisplayUUID = fresh.selectedDisplayUUID
        collapsedPresetIDs = fresh.collapsedPresetIDs
        selectedTopologyRecord = topologies.first { $0.key == fresh.selectedKey }
        expandedDetails = details(for: fresh)
        state = fresh
    }

    /// 侧栏选中拓扑（清除屏筛选与收起，详情重新全部展开）
    public func selectTopology(_ key: String) {
        manualSelectedKey = key
        selectedDisplayUUID = nil
        collapsedPresetIDs = []
        reload()
    }

    /// 回到跟随当前拓扑（主窗口经菜单「管理预设…」打开时；清除屏筛选与收起，ui-refactor 票 03）
    public func selectCurrentTopology() {
        manualSelectedKey = nil
        selectedDisplayUUID = nil
        collapsedPresetIDs = []
        reload()
    }

    /// 排列图点选屏：再点同一块 = 取消筛选（display-presets 票 08 预设详情据 state.selectedDisplayUUID 只显示该屏）
    public func selectDisplay(_ uuid: String?) {
        selectedDisplayUUID = uuid == selectedDisplayUUID ? nil : uuid
        reload()
    }

    /// 收起/展开预设详情（display-presets 票 08；默认展开，ui-refactor 票 10）
    public func toggleExpanded(presetID: String) {
        if collapsedPresetIDs.remove(presetID) == nil { collapsedPresetIDs.insert(presetID) }
        reload()
    }

    /// 某预设块展开时的详情（收起或不存在为 nil）
    public func detail(presetID: String) -> PresetDetail? { expandedDetails[presetID] }

    // MARK: 预设块操作

    /// 「保存当前布局…」（仅当前拓扑且可用）
    public func savePreset() {
        guard state.selected?.canSavePreset == true else { return }
        saveAction()
    }

    /// 预设块 `⋯` 菜单项（ui-refactor 票 04）：分派到覆盖 / 改名 / 删除，可用性仍由各操作自行把关
    public func perform(_ action: PresetRowAction, presetID: String) {
        switch action {
        case .overwrite: overwrite(presetID: presetID)
        case .rename: rename(presetID: presetID)
        case .delete: delete(presetID: presetID)
        }
    }

    public func restore(presetID: String) {
        guard let (key, row) = selectedRow(presetID), row.canRestore else { return }
        restoreAction(presetID, key)
    }

    public func overwrite(presetID: String) {
        guard let (key, row) = selectedRow(presetID), row.canOverwrite else { return }
        overwriteFlow.runAsync(presetID: presetID, topologyKey: key) { [weak self] _ in self?.reload() }
    }

    public func rename(presetID: String) {
        guard let (key, row) = selectedRow(presetID) else { return }
        var proposed = row.name
        var message: String?
        // 撞名/空名：提示后带着刚输入的名称重弹，直到改成或取消（spec §4.1）
        while let name = dialogs.promptRename(currentName: proposed, message: message) {
            do {
                try store.renamePreset(id: presetID, topologyKey: key, to: name)
                break
            } catch PresetStoreError.duplicateName(let existing) {
                message = "已有名为「\(existing)」的预设，请换一个名称"
            } catch PresetStoreError.emptyName {
                message = "名称不能为空"
            } catch {
                fail("改名失败", error)
                break
            }
            proposed = name
        }
        reload()
    }

    public func delete(presetID: String) {
        guard let (key, row) = selectedRow(presetID), dialogs.confirmDelete(presetName: row.name) else { return }
        perform("删除失败") { try store.deletePreset(id: presetID, topologyKey: key) }
    }

    /// 自动开关（设为自动 = 同拓扑其他预设自动清除，存储保证互斥）
    public func setAuto(_ isAuto: Bool, presetID: String) {
        guard let key = state.selectedKey else { return }
        perform("设置自动失败") { try store.setAuto(isAuto, presetID: presetID, topologyKey: key) }
    }

    /// 改选中拓扑的别名（空白 = 清除，回到默认屏名组合）
    public func editAlias() {
        guard let selected = state.selected, selected.canEditAlias else { return }
        let alias = store.topology(key: selected.key)?.alias
        let placeholder = PresetManagerState.defaultTitle(for: selected.displays)
        guard let answer = dialogs.promptAlias(currentAlias: alias, placeholder: placeholder) else { return }
        perform("修改名称失败") { try store.setAlias(answer, topologyKey: selected.key) }
    }

    // MARK: 内部

    /// 各展开预设块的详情推导（纯计算在 PresetDetail）
    private func details(for state: PresetManagerState) -> [String: PresetDetail] {
        guard let selected = state.selected, let presets = selectedTopologyRecord?.presets else { return [:] }
        var details: [String: PresetDetail] = [:]
        for preset in presets where state.isDetailExpanded(presetID: preset.id) {
            details[preset.id] = PresetDetail.make(snapshot: preset.snapshot, displays: selected.displays,
                                                   displayFilter: state.selectedDisplayUUID, appName: appName)
        }
        return details
    }

    private func selectedRow(_ presetID: String) -> (String, PresetRowState)? {
        guard let selected = state.selected, let row = selected.rows.first(where: { $0.id == presetID }) else {
            return nil
        }
        return (selected.key, row)
    }

    private func perform(_ failureTitle: String, _ work: () throws -> Void) {
        do { try work() } catch { fail(failureTitle, error) }
        reload()
    }

    private func fail(_ title: String, _ error: Error) {
        let reason: String
        switch error as? PresetStoreError {
        case .presetNotFound?: reason = "预设不存在（可能已被删除）"
        case .topologyNotFound?: reason = "该屏幕排列尚无记录"
        default: reason = String(describing: error)
        }
        dialogs.showError("\(title)：\(reason)")
    }
}
