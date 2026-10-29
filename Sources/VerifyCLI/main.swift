import AppKit
import CoreGraphics
import Darwin
import Foundation
import Core

// VerifyCLI — 验证器雏形（票 11，spec §9.1）。
// 用法：swift run VerifyCLI [--snapshot <file.json>]
//   --snapshot <file.json>  指定快照文件；缺省 = 当前拓扑的现势快照（无则报错退出）
// 从已授权终端运行（继承宿主 TCC；CLI 本身无需签名授权）。
// 实时枚举：CGWindowListCopyWindowInfo(.optionAll) 全量窗口（含其他 Space/最小化）
//   + _AXUIElementGetWindow 配对（照 05 spike 写法；票 13 将下沉到 AXFacade）。
// 逐条输出 PASS / FAIL / SKIP 雏形报告（此阶段几何+标题比对，spec §9.1）。
// 退出码：0 = 报告产出；2 = 用法/快照错误；3 = 授权未齐（明确提示，不崩溃）。

private let usage = """
usage: swift run VerifyCLI [--snapshot <file.json>]
  --snapshot <file.json>   指定快照文件；缺省 = 当前拓扑现势快照（无则报错退出）
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

// MARK: - CG 全量窗口枚举

/// CGWindowList .optionAll 的 layer-0 窗口（含其他 Space / 最小化，spec §7.5）
private struct CGWindowRecord {
    let wid: UInt32
    let bundleID: String
    let title: String?      // kCGWindowName 需屏幕录制权限，可能为 nil
    let bounds: CGRect      // 全局坐标
    let pid: pid_t
}

// CGWindowList 字典里 bundle ID 的键名（SDK 未导出常量，实测返回字典含此键；macOS 15）
private let kCGWindowBundleIDKey = "kCGWindowBundleID"

private func enumerateCGWindows() -> [CGWindowRecord] {
    let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    var records: [CGWindowRecord] = []
    for dict in raw {
        let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
        guard layer == 0 else { continue }  // 只取普通窗口层（菜单/Dock 等系统层排除）
        guard let wid = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value, wid != 0 else { continue }
        guard let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary else { continue }
        var bounds = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &bounds),
              bounds.width >= 40, bounds.height >= 40 else { continue }  // 40px 以下按辅助窗排除（spike: cmuxterm 24×24）
        let pid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        var bundleID = dict[kCGWindowBundleIDKey as String] as? String ?? ""
        if bundleID.isEmpty, let app = NSRunningApplication(processIdentifier: pid) {
            bundleID = app.bundleIdentifier ?? ""
        }
        guard !bundleID.isEmpty else { continue }
        let title = dict[kCGWindowName as String] as? String
        records.append(CGWindowRecord(wid: wid, bundleID: bundleID, title: title, bounds: bounds, pid: pid))
    }
    return records
}

/// 窗口中心点归属显示器：包含则取之，否则取中心距离最近者（跨屏窗口兜底）
private func displayFor(window rect: CGRect, displays: [Displays.Info]) -> Displays.Info? {
    guard !displays.isEmpty else { return nil }
    let center = CGPoint(x: rect.midX, y: rect.midY)
    if let hit = displays.first(where: { $0.bounds.contains(center) }) { return hit }
    return displays.min {
        hypot($0.bounds.midX - center.x, $0.bounds.midY - center.y)
        < hypot($1.bounds.midX - center.x, $1.bounds.midY - center.y)
    }
}

private func ratio(_ rect: CGRect, in bounds: CGRect) -> (x: Double, y: Double, w: Double, h: Double) {
    guard bounds.width > 0, bounds.height > 0 else { return (0, 0, 0, 0) }
    return (Double((rect.minX - bounds.minX) / bounds.width),
            Double((rect.minY - bounds.minY) / bounds.height),
            Double(rect.width / bounds.width),
            Double(rect.height / bounds.height))
}

// MARK: - 输出辅助

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

    // 实时枚举：CG 全量 + AX 配对 → LiveWindow（比例坐标）
    let cgWindows = enumerateCGWindows()
    let axByWid = axWindowsByCGWindowID()
    var liveWindows: [LiveWindow] = []
    var liveDisplayUUID: [String?] = []
    for record in cgWindows {
        guard let display = displayFor(window: record.bounds, displays: displays) else { continue }
        let r = ratio(record.bounds, in: display.bounds)
        let ax = axByWid[record.wid]
        let title = record.title ?? ax?.title ?? ""
        liveWindows.append(LiveWindow(cgWindowID: record.wid, bundleID: record.bundleID, title: title,
                                      x: r.x, y: r.y, w: r.w, h: r.h,
                                      minimized: ax?.minimized ?? false))
        liveDisplayUUID.append(display.uuid)
    }

    // 保守匹配：与 app 共用同一份 Core 代码（spec §7.1 / 08 #1）
    let outcome = ConservativeMatcher.match(snapshotWindows: snapshot.windows, liveWindows: liveWindows)
    let matchBySnapshot = Dictionary(uniqueKeysWithValues: outcome.matches.map { ($0.snapshotIndex, $0) })
    let liveBundleIDs = Set(liveWindows.map(\.bundleID))

    // 报告
    let dateFormatter = ISO8601DateFormatter()
    print("== VerifyCLI 雏形报告（票 11，spec §9.1）==")
    print("快照: \(snapshotURL.path)")
    print("  version=\(snapshot.version) capturedAt=\(dateFormatter.string(from: snapshot.capturedAt)) "
        + "displays=\(snapshot.topology.count) spaces=\(snapshot.spaces.count) windows=\(snapshot.windows.count)")
    print("实时: 当前拓扑 key=\(topologyKey.prefix(24))… 屏=\(displays.count) "
        + "CG 窗口(layer0)=\(cgWindows.count) AX 配对=\(axByWid.count) 参与匹配=\(liveWindows.count)")
    print("授权: 辅助功能=✓ 屏幕录制=✓")
    print(String(repeating: "-", count: 72))

    var pass = 0, fail = 0, skip = 0
    for (s, snapshotWindow) in snapshot.windows.enumerated() {
        if let match = matchBySnapshot[s] {
            let live = liveWindows[match.liveIndex]
            let deltas = [abs(snapshotWindow.x - live.x), abs(snapshotWindow.y - live.y),
                          abs(snapshotWindow.w - live.w), abs(snapshotWindow.h - live.h)]
            let delta = deltas.max() ?? 0
            let titleNote = match.viaGeometryFallback ? "（兜底「\(snapshotWindow.title)」→「\(live.title)」）" : ""
            // 雏形容差：同分辨率同旋转下比例坐标应逐位相等；1e-6 吸收浮点串化噪声（§9.3 终验时收紧为精确相等）
            if delta <= 1e-6 {
                pass += 1
                var extra = ""
                if snapshotWindow.minimized != live.minimized {
                    extra = "  最小化 快照=\(snapshotWindow.minimized ? "是" : "否") 实际=\(live.minimized ? "是" : "否")"
                }
                if let sd = snapshot.topology.first(where: { $0.uuid == snapshotWindow.displayUUID })?.localizedName {
                    extra += "  屏=\(sd)"
                }
                print("PASS  #\(s)  wid=\(live.cgWindowID)  app=\(pad(snapshotWindow.bundleID, 24)) 标题=「\(snapshotWindow.title)」\(titleNote)  geoΔ=\(String(format: "%.6f", delta))\(extra)")
            } else {
                fail += 1
                print("FAIL  #\(s)  wid=\(live.cgWindowID)  app=\(pad(snapshotWindow.bundleID, 24)) 标题=「\(snapshotWindow.title)」\(titleNote)  geoΔ=\(String(format: "%.6f", delta))")
                print("      期望=\(geoString(snapshotWindow)) 实际=(\(String(format: "%.4f", live.x)),\(String(format: "%.4f", live.y)),\(String(format: "%.4f", live.w)),\(String(format: "%.4f", live.h)))")
            }
        } else {
            skip += 1
            let reason = liveBundleIDs.contains(snapshotWindow.bundleID)
                ? "unmatched（保守匹配不猜：同应用在跑但键/几何均未配上）"
                : "app-not-running（快照有、当前未运行，不启动，spec §6.4a）"
            print("SKIP  #\(s)        app=\(pad(snapshotWindow.bundleID, 24)) 标题=「\(snapshotWindow.title)」  原因=\(reason)")
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
