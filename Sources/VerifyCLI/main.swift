import AppKit
import CoreGraphics
import Darwin
import Foundation
import Core
import SpaceAdapter

// VerifyCLI — 验证器（票 11 起步雏形，票 14 升级全量比对，spec §9.1）。
// 用法：swift run VerifyCLI [--snapshot <file.json>]
//   --snapshot <file.json>  指定快照文件；缺省 = 当前拓扑的现势快照（无则报错退出）
// 从已授权终端运行（继承宿主 TCC；CLI 本身无需签名授权）。
// 实时枚举：CGWindowListCopyWindowInfo(.optionAll) 全量窗口（含其他 Space/最小化）
//   + _AXUIElementGetWindow 配对（照 05 spike 写法）。
// 全量比对：预期 SKIP 集推导复用同一份 Core.ConservativeMatcher（app 恢复管线同源，08 #1）；
//   逐条 PASS / FAIL / SKIP + 屏幕归属比对；Space 归属（L2）经 SpaceAdapter 查 SLS，
//   本进程无授权/符号缺失时相关项按「无法核验」标注（不崩、不阻断）。
//   判定口径与 RestoreEngine.VerifyComparer 单测对齐（VerifyCLI 目标依赖表未含 RestoreEngine，
//   Package.swift 冻结；几何容差 1e-6 / reasons / skip reason 字符串须同步维护）。
// 退出码：0 = 报告产出；2 = 用法/快照错误；3 = 授权未齐（明确提示，不崩溃）。

private let usage = """
usage: swift run VerifyCLI [--snapshot <file.json>]
  --snapshot <file.json>   指定快照文件；缺省 = 当前拓扑现势快照（无则报错退出）
全量比对：逐条 PASS/FAIL/SKIP + 屏幕归属 + Space 归属（无法核验时标注不阻断，spec §9.1）
exit codes: 0 报告产出 / 2 用法或快照错误 / 3 授权未齐
"""

// MARK: - 私有 API 加载（照 spike：dlsym，无链接期依赖）

private func loadSym<T>(_ lib: String, _ name: String, as type: T.Type) -> T? {
    let h = lib.isEmpty ? dlopen(nil, RTLD_LAZY) : dlopen(lib, RTLD_LAZY)
    guard let hh = h, let p = dlsym(hh, name) else { return nil }
    return unsafeBitCast(p, to: type)
}

private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
private let axGetWindow: AXGetWindowFn? = [
    "/System/Library/PrivateFrameworks/HIServices.framework/HIServices",
    "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
    "",
].lazy.compactMap { loadSym($0, "_AXUIElementGetWindow", as: AXGetWindowFn.self) }.first

// MARK: - AX 辅助（照 spike）

private func axAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}
private func axWindows(_ app: AXUIElement) -> [AXUIElement] {
    guard let v = axAttr(app, "AXWindows") else { return [] }
    return (v as! NSArray).compactMap { el -> AXUIElement? in (el as! AXUIElement) }  // 照 spike 强转；括号消 forced-downcast-in-optional 警告
}
private func axTitle(_ el: AXUIElement) -> String { axAttr(el, "AXTitle") as? String ?? "" }
private func axBoolAttr(_ el: AXUIElement, _ name: String) -> Bool {
    guard let v = axAttr(el, name) else { return false }
    return CFGetTypeID(v) == CFBooleanGetTypeID() && CFEqual(v as CFTypeRef, kCFBooleanTrue)
}
private func axPoint(_ el: AXUIElement) -> CGPoint? {
    guard let v = axAttr(el, "AXPosition"), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
}
private func axSize(_ el: AXUIElement) -> CGSize? {
    guard let v = axAttr(el, "AXSize"), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
}

/// 单个存活窗口的 AX 配对信息（wid → 元数据）
private struct AxWindowInfo {
    let title: String
    let minimized: Bool
}

/// _AXUIElementGetWindow 配对：遍历所有可访应用的 AXWindows，wid 即 CGWindowNumber（05 spike 实测）
private func axWindowsByCGWindowID() -> [UInt32: AxWindowInfo] {
    guard axGetWindow != nil else { return [:] }
    var out: [UInt32: AxWindowInfo] = [:]
    for app in NSWorkspace.shared.runningApplications
    where app.processIdentifier > 0 && app.activationPolicy != .prohibited {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        for w in axWindows(appEl) {
            var wid: UInt32 = 0
            guard axGetWindow?(w, &wid) == .success, wid != 0 else { continue }
            let minimized = axBoolAttr(w, "AXMinimized")
            out[wid] = AxWindowInfo(title: axTitle(w), minimized: minimized)
        }
    }
    return out
}

// MARK: - 输出辅助

/// 几何相等容差：与 RestoreEngine.VerifyComparer.geometryTolerance 同值（判定口径对齐，
/// 见文件头注；RestoreEngine 单测钉死该值，两端须同步维护）
private enum VerifyComparerConstants {
    static let geometryTolerance = 1e-6
}

private func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}
private func geoString(_ s: SnapshotWindow) -> String {
    "(\(String(format: "%.4f", s.x)),\(String(format: "%.4f", s.y)),\(String(format: "%.4f", s.w)),\(String(format: "%.4f", s.h)))"
}

// MARK: - main

func main() {
    let args = CommandLine.arguments.dropFirst()
    if args.contains("--help") || args.contains("-h") {
        print(usage)
        exit(0)
    }
    var snapshotPath: String?
    var i = args.startIndex
    while i < args.endIndex {
        if args[i] == "--snapshot", args.indices.contains(i + 1) {
            snapshotPath = args[i + 1]
            i += 2
        } else {
            fputs("verify: 未知参数 \(args[i])\n\(usage)\n", stderr)
            exit(2)
        }
    }

    // 授权前置：从已授权终端运行继承宿主 TCC；缺权时明确提示而非崩溃（票面要求）
    let axOk = AXIsProcessTrusted()
    let screenOk = CGPreflightScreenCaptureAccess()
    guard axOk, screenOk else {
        fputs("""
        verify: 授权未齐，无法枚举窗口（从已授权终端运行可继承宿主 TCC）
          辅助功能:   \(axOk ? "✓" : "✗ 缺少 — 系统设置 → 隐私与安全性 → 辅助功能，为宿主终端 App 开启")
          屏幕录制:   \(screenOk ? "✓" : "✗ 缺少 — 系统设置 → 隐私与安全性 → 屏幕与系统录音，为宿主终端 App 开启")
        开启后重启终端再试。
        """, stderr)
        exit(3)
    }

    // 快照来源：--snapshot 指定，或当前拓扑现势快照
    let displays = Displays.active()
    guard !displays.isEmpty else {
        fputs("verify: 未枚举到任何显示器\n", stderr)
        exit(2)
    }
    let store = SnapshotStore(directory: SnapshotStore.defaultDirectory)
    let topologyKey = SnapshotStore.topologyKey(forDisplayUUIDs: displays.compactMap(\.uuid))
    let snapshotURL: URL
    if let path = snapshotPath {
        snapshotURL = URL(fileURLWithPath: path)
    } else {
        snapshotURL = store.liveURL(topologyKey: topologyKey)
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            fputs("verify: 当前拓扑无现势快照（期待 \(snapshotURL.lastPathComponent)）；用 --snapshot <file.json> 指定，或先运行 app 落盘\n", stderr)
            exit(2)
        }
    }
    guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
        fputs("verify: 快照文件不存在：\(snapshotURL.path)\n", stderr)
        exit(2)
    }
    let snapshot: Snapshot
    do {
        snapshot = try Snapshot.decode(from: Data(contentsOf: snapshotURL))
    } catch SnapshotSchemaError.unsupportedVersion(let found, let supported) {
        fputs("verify: 快照版本过高拒用（found=\(found) supported=\(supported)，spec §7.3 不迁移）：\(snapshotURL.path)\n", stderr)
        exit(2)
    } catch SnapshotSchemaError.invalidVersion(let found) {
        fputs("verify: 快照 version 非法（\(found)）：\(snapshotURL.path)\n", stderr)
        exit(2)
    } catch {
        fputs("verify: 快照解析失败（\((error as? DecodingError).map(String.init(describing:)) ?? "\(error)")）：\(snapshotURL.path)\n", stderr)
        exit(2)
    }

    // Space 数据：经 SpaceAdapter 查 SLS，供屏归属（Space 所属屏优先）与 Space 归属（L2）比对。
    // 本进程无授权 / SkyLight 符号缺失时查询抛错 → 空表 = 屏归属按 frame 兜底、Space 项「无法核验」，不崩（票面要求）。
    let adapter = SpaceAdapter()
    var spaceIDByWindow: [UInt32: Int64] = [:]
    var spaceEntries: [SpaceEntry] = []
    if let byWindow = try? adapter.spaceIDsByWindowID(),
       let entries = try? adapter.managedSpaces() {
        spaceIDByWindow = byWindow
        spaceEntries = entries
    }

    // 实时枚举：CG 全量（与 app 同一份 Core 采样）→ 屏归属 + 比例几何（Core.LiveWindowLocator）+ AX 配对
    let cgWindows = CGWindowListEnumerator().sample()
    let located = LiveWindowLocator.locate(samples: cgWindows, displays: displays,
                                           spaceIDByWindow: spaceIDByWindow, spaceEntries: spaceEntries)
    let axByWid = axWindowsByCGWindowID()
    var liveWindows: [LiveWindow] = []
    var displayUUIDByWindowID: [UInt32: String] = [:]
    var spaceEntryByWindowID: [UInt32: SpaceEntry] = [:]
    for lw in located {
        let wid = lw.sample.windowID
        let ax = axByWid[wid]
        let title = lw.sample.title ?? ax?.title ?? ""
        liveWindows.append(LiveWindow(cgWindowID: wid, bundleID: lw.sample.bundleID, title: title,
                                      x: lw.x, y: lw.y, w: lw.w, h: lw.h,
                                      minimized: ax?.minimized ?? false))
        displayUUIDByWindowID[wid] = lw.display.uuid
        spaceEntryByWindowID[wid] = lw.space
    }

    // 保守匹配：与 app 共用同一份 Core 代码（spec §7.1 / 08 #1）
    let outcome = ConservativeMatcher.match(snapshotWindows: snapshot.windows, liveWindows: liveWindows)
    let matchBySnapshot = Dictionary(uniqueKeysWithValues: outcome.matches.map { ($0.snapshotIndex, $0) })
    let liveBundleIDs = Set(liveWindows.map(\.bundleID))

    // 报告
    let dateFormatter = ISO8601DateFormatter()
    print("== VerifyCLI 全量比对报告（票 14，spec §9.1）==")
    print("快照: \(snapshotURL.path)")
    print("  version=\(snapshot.version) capturedAt=\(dateFormatter.string(from: snapshot.capturedAt)) "
        + "displays=\(snapshot.topology.count) spaces=\(snapshot.spaces.count) windows=\(snapshot.windows.count)")
    print("实时: 当前拓扑 key=\(topologyKey.prefix(24))… 屏=\(displays.count) "
        + "CG 窗口(layer0)=\(cgWindows.count) AX 配对=\(axByWid.count) 参与匹配=\(liveWindows.count)")
    print("授权: 辅助功能=✓ 屏幕录制=✓  Space 归属=\(spaceEntryByWindowID.isEmpty ? "无法核验（本进程无 SLS 授权）" : "\(spaceEntryByWindowID.count) 窗口可查")")
    print(String(repeating: "-", count: 72))

    var pass = 0, fail = 0, skip = 0
    for (s, snapshotWindow) in snapshot.windows.enumerated() {
        guard let match = matchBySnapshot[s] else {
            // 预期 SKIP 推导：共享 Core.ConservativeMatcher 的未配对集合（app 恢复管线同源判定）
            skip += 1
            let reason = liveBundleIDs.contains(snapshotWindow.bundleID)
                ? "unmatched（保守匹配不猜：同应用在跑但键/几何均未配上）"
                : "app-not-running（快照有、当前未运行，不启动，spec §6.4a）"
            print("SKIP  #\(s)        app=\(pad(snapshotWindow.bundleID, 24)) 标题=「\(snapshotWindow.title)」  原因=\(reason)")
            continue
        }
        let live = liveWindows[match.liveIndex]
        if snapshotWindow.minimized || live.minimized {
            // L4 归票 15（引擎计划同因跳过）：快照 minimized 条目 / 实况最小化窗口 = 预期跳过
            skip += 1
            let reason = snapshotWindow.minimized
                ? "minimized-entry-L4（最小化恢复归票 15，当前保守不动）"
                : "live-minimized（实况最小化，保守不动，L4 归口票 15）"
            print("SKIP  #\(s)  wid=\(live.cgWindowID)  app=\(pad(snapshotWindow.bundleID, 24)) 标题=「\(snapshotWindow.title)」  原因=\(reason)")
            continue
        }
        // 判定口径与 RestoreEngine.VerifyComparer 对齐（该文件单测钉死容差与 reason 字符串）
        let delta = max(abs(snapshotWindow.x - live.x), abs(snapshotWindow.y - live.y),
                        abs(snapshotWindow.w - live.w), abs(snapshotWindow.h - live.h))
        var reasons: [String] = []
        if delta > VerifyComparerConstants.geometryTolerance { reasons.append("geometry") }
        let displayMatched = displayUUIDByWindowID[live.cgWindowID].map { $0 == snapshotWindow.displayUUID }
        if let matched = displayMatched, !matched { reasons.append("display") }
        let spaceEntry = spaceEntryByWindowID[live.cgWindowID]
        let spaceMatched = spaceEntry.map { $0.index == snapshotWindow.spaceIndex }
        if let matched = spaceMatched, !matched { reasons.append("space") }

        let titleNote = match.viaGeometryFallback ? "（兜底「\(snapshotWindow.title)」→「\(live.title)」）" : ""
        let screenName = snapshot.topology.first(where: { $0.uuid == snapshotWindow.displayUUID })?.localizedName
        if reasons.isEmpty {
            pass += 1
            var extra = ""
            if let screenName { extra += "  屏=\(screenName)\(displayMatched == nil ? "(无法核验)" : " ✓")" }
            if spaceMatched != nil {
                extra += "  Space=#\(snapshotWindow.spaceIndex) ✓"
            } else {
                extra += "  Space=无法核验（本进程无 SLS 授权）"
            }
            print("PASS  #\(s)  wid=\(live.cgWindowID)  app=\(pad(snapshotWindow.bundleID, 24)) 标题=「\(snapshotWindow.title)」\(titleNote)  geoΔ=\(String(format: "%.6f", delta))\(extra)")
        } else {
            fail += 1
            print("FAIL  #\(s)  wid=\(live.cgWindowID)  app=\(pad(snapshotWindow.bundleID, 24)) 标题=「\(snapshotWindow.title)」\(titleNote)  原因=\(reasons.joined(separator: ","))")
            print("      期望=\(geoString(snapshotWindow)) 实际=(\(String(format: "%.4f", live.x)),\(String(format: "%.4f", live.y)),\(String(format: "%.4f", live.w)),\(String(format: "%.4f", live.h)))")
            if let matched = displayMatched, !matched, let screenName {
                print("      屏幕归属: 期望=\(screenName)(\(snapshotWindow.displayUUID)) 实际=\(displayUUIDByWindowID[live.cgWindowID] ?? "?")")
            }
            if let matched = spaceMatched, !matched {
                print("      Space 归属: 期望=#\(snapshotWindow.spaceIndex) 实际=#\(spaceEntry?.index ?? -1)")
            }
        }
    }

    print(String(repeating: "-", count: 72))
    let unmatchedLive = outcome.unmatchedLiveIndexes
    print("快照外窗口（保守匹配一律不动，spec §6.4b）: \(unmatchedLive.count) 个")
    for l in unmatchedLive.prefix(5) {
        let live = liveWindows[l]
        print("  · wid=\(live.cgWindowID) app=\(live.bundleID) 标题=「\(live.title)」")
    }
    if unmatchedLive.count > 5 {
        print("  … 其余 \(unmatchedLive.count - 5) 个略")
    }
    print("汇总: 快照条目 \(snapshot.windows.count) = PASS \(pass) + FAIL \(fail) + SKIP \(skip)")
    exit(0)
}

main()
