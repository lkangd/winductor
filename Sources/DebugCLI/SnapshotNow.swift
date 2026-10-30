import Core
import Foundation
import SnapshotEngine

// SnapshotNow.swift — 调试子命令 snapshot-now（票 12）。
// 手动触发一次差分 + 落盘：打印单次差分耗时（对照 04 基线 optionAll ≈6.7ms）、
// 产出路径与 mtime，供票面验收「动窗口后经防抖窗口快照更新（mtime 可查）」手动核对。
// SpaceProviding 实现由票 13 提供：本命令当前以 spaces=nil（降级：spaces=[]、spaceIndex=1）
// 构造引擎；票 17/18 接线时注入 SpaceAdapter 实现即可。
// 用法：swift run DebugCLI snapshot-now [--dir <快照目录>] [--watch <秒>]
//   --dir   落盘目录（默认 ~/Library/Application Support/WindowLayoutRestorer/snapshots/）
//   --watch 挂起引擎 N 秒（照常 2s 轮询+1s 防抖+加速器），live mtime 变化时打印，
//           退出前列 1+4 滚动文件——验收「动窗口后 mtime 可查 / 1+4 滚动」用

func runSnapshotNow() -> Int32 {
    var directory = SnapshotStore.defaultDirectory
    // Array() 具体化：dropFirst() 返回的 ArraySlice 保留原索引（下标从 1 起），
    // 直接用 firstIndex + count 比较会差一错位（尾部参数对被误判越界）
    let args = Array(CommandLine.arguments.dropFirst())
    if let i = args.firstIndex(of: "--dir"), args.count > i + 1 {
        directory = URL(fileURLWithPath: args[args.index(after: i)])
    }

    let log = FileLogSink(directory: SnapshotStore.defaultLogDirectory, fileName: "debug-snapshot.log")
    let store = SnapshotStore(directory: directory, log: log)
    let engine = SnapshotEngine(store: store, spaces: nil, log: log)

    _ = CGWindowListEnumerator().sample()  // warmup：首次调用含窗口服务连接建立，不入计时
    let t0 = DispatchTime.now()
    let changed = engine.pollNow()
    let diffMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
    engine.writePendingNow()  // 手动强制写（正式路径由 1s 防抖触发）

    let uuids = Displays.active().compactMap(\.uuid)
    let key = SnapshotStore.topologyKey(forDisplayUUIDs: uuids)
    let liveURL = store.liveURL(topologyKey: key)
    print("diff=\(changed ? "changed" : "no-change") 单次差分=\(String(format: "%.2f", diffMs)) ms（04 基线 6.7ms）")
    print("topology-key=\(key)")

    // --watch N：挂起引擎 N 秒，live mtime 变化即打印；退出前列 1+4 滚动文件
    if let i = args.firstIndex(of: "--watch"), args.count > i + 1,
       let seconds = Double(args[args.index(after: i)]) {
        let formatter = ISO8601DateFormatter()
        print("watch: 引擎挂起 \(seconds)s（2s 轮询 + 1s 防抖 + 启退/屏幕事件加速器）…")
        engine.start()
        let deadline = Date().addingTimeInterval(seconds)
        var lastLiveMTime: Date?
        while Date() < deadline {
            usleep(300_000)
            let attrs = try? FileManager.default.attributesOfItem(atPath: liveURL.path)
            let mtime = attrs?[.modificationDate] as? Date
            if let mtime, mtime != lastLiveMTime {
                print("watch: live 快照更新 mtime=\(formatter.string(from: mtime))")
                lastLiveMTime = mtime
            }
        }
        engine.stop()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.sorted() ?? []
        print("watch: 结束，目录内容（应 1 live + 4 history）：")
        for f in files where f.hasPrefix("live-") || f.hasPrefix("history-") {
            let attrs = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(f).path)
            let mtime = attrs?[.modificationDate] as? Date ?? Date()
            print("  \(f)  mtime=\(formatter.string(from: mtime))")
        }
    }

    if FileManager.default.fileExists(atPath: liveURL.path) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: liveURL.path)
        let mtime = attrs?[.modificationDate] as? Date ?? Date()
        let formatter = ISO8601DateFormatter()
        print("live=\(liveURL.path)")
        print("mtime=\(formatter.string(from: mtime))")
        // 自解析：与 VerifyCLI 同一 Snapshot.decode 路径（verify 全流程需授权，票 18/19 从已授权进程验收）
        do {
            let parsed = try Snapshot.decode(from: Data(contentsOf: liveURL))
            print("parse=ok version=\(parsed.version) displays=\(parsed.topology.count) spaces=\(parsed.spaces.count) windows=\(parsed.windows.count)")
        } catch {
            print("parse=FAIL \(error)")
            return 1
        }
    } else {
        print("live=<未产出>（检查屏幕录制权限：未授权时 kCGWindowName/title 为 nil，但不阻止写盘）")
    }
    return 0
}
