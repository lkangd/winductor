import AXFacade
import Core
import Foundation
import SpaceAdapter

// MoveWindow — 桥接移窗调试命令（票 13 验收第 2 项；spec §5.1 桥接路径 + §10.2 no-op 识别演示面）。
// 用法：move-window <wid> <displayUUID|dispIdx> <spaceIdx>
// dispIdx/spaceIdx 与 list-spaces 输出一一对应（显示器按 SLSCopyManagedDisplaySpaces 首现序，Space 每屏 1 起）。

enum MoveWindow {
    static let usage = "usage: swift run DebugCLI move-window <wid> <displayUUID|dispIdx> <spaceIdx>"

    static func run(_ args: [String]) -> Int32 {
        guard args.count == 3, let wid = UInt32(args[0]), let targetSpaceIndex = Int(args[2]) else {
            print(usage)
            return 2
        }
        // 第二参：纯数字 = dispIdx，否则按完整 displayUUID 匹配；第三参：每屏 1 起 spaceIdx
        let displayArg = args[1]
        let adapter = SpaceAdapter(log: ConsoleLogSink.shared)
        do {
            let entries = try adapter.managedSpaces()
            var displayOrder: [String] = []
            for e in entries where !displayOrder.contains(e.displayUUID) { displayOrder.append(e.displayUUID) }
            let targetDisplay: String
            if let dispIdx = Int(displayArg) {
                guard displayOrder.indices.contains(dispIdx) else {
                    print("FAIL: display index \(dispIdx) out of range 0..<\(displayOrder.count) (see list-spaces)")
                    return 1
                }
                targetDisplay = displayOrder[dispIdx]
            } else {
                guard displayOrder.contains(displayArg) else {
                    print("FAIL: unknown display uuid \(displayArg) (see list-spaces)")
                    return 1
                }
                targetDisplay = displayArg
            }
            guard let target = entries.first(where: { $0.displayUUID == targetDisplay && $0.index == targetSpaceIndex }) else {
                print("FAIL: display \(targetDisplay) has no space #\(targetSpaceIndex) (see list-spaces)")
                return 1
            }
            let kindName = target.kind == 0 ? "user" : (target.kind == 4 ? "fullscreen" : "?kind=\(target.kind)")
            print("target: display uuid=\(targetDisplay) space #\(target.index) id64=\(target.spaceID) kind=\(target.kind)(\(kindName))")
            print("before: wid=\(wid) spaces=\(try adapter.spaceIDs(windowID: wid)) disp=\(try adapter.displayUUID(windowID: wid) ?? "?") \(axFrameLine(wid))")
            guard adapter.isLayerAvailable(.bridge) else {
                print("RESULT: refused — bridge layer unavailable (\(adapter.probeLayer(.bridge).detail))")
                return 1
            }
            let moved = try adapter.moveWindowsToSpace(windowIDs: [wid], spaceID: target.spaceID)
            print("after:  wid=\(wid) spaces=\(try adapter.spaceIDs(windowID: wid)) disp=\(try adapter.displayUUID(windowID: wid) ?? "?") \(axFrameLine(wid))")
            print(moved ? "RESULT: moved" : "RESULT: no-op — bridge layer degraded ([degrade] line above)")
            return moved ? 0 : 1
        } catch let error as SpaceAdapterError {
            print("FAIL: \(error)")
            return 1
        } catch {
            print("FAIL: \(error)")
            return 1
        }
    }

    /// AXFacade 只读快照（位置/尺寸/最小化/全屏），顺带验收 AX 门面读路径；元素找不到（如全屏后台窗口）报 ax=unseen
    private static func axFrameLine(_ wid: UInt32) -> String {
        guard let el = AXFacade.findWindow(withWindowID: wid) else { return "ax=unseen" }
        let pos = (try? AXFacade.position(of: el)).map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "?"
        let size = (try? AXFacade.size(of: el)).map { "\(Int($0.width))×\(Int($0.height))" } ?? "?"
        let min = (try? AXFacade.isMinimized(of: el)) ?? false
        let fs = (try? AXFacade.isFullScreen(of: el)) ?? false
        return "ax=pos=\(pos) size=\(size) min=\(min ? "Y" : "n") fs=\(fs ? "Y" : "n")"
    }
}
