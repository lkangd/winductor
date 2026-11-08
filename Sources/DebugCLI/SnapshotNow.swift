import Core
import Foundation
import SnapshotEngine

// SnapshotNow.swift — 调试子命令 snapshot-now（票 12；票 02 起现势快照只在内存，不落盘）。
// 手动触发一次差分 + 组装：打印单次差分耗时（对照 04 基线 optionAll ≈6.7ms）与快照摘要；
// --out 把快照写成文件（供 restore / VerifyCLI --snapshot 使用）。保存为预设归票 09。
// SpaceProviding 以 spaces=nil 构造（降级：spaces=[]、spaceIndex=1）。
// 用法：swift run DebugCLI snapshot-now [--out <文件>] [--watch <秒>]
//   --out   快照写入路径（原子写；缺省不落盘）
//   --watch 挂起引擎 N 秒（照常 2s 轮询+1s 防抖+加速器），快照更新时打印

enum SnapshotNow {
    // args 已由 main.swift 去除子命令名（票 13 注册表约定）
    static func run(_ args: [String]) -> Int32 {
    let log = FileLogSink(directory: SnapshotStore.defaultLogDirectory, fileName: "debug-snapshot.log")
    let store = TransitionalLiveSnapshots(log: log)
    let engine = SnapshotEngine(store: store, spaces: nil, log: log)

    _ = CGWindowListEnumerator().sample()  // warmup：首次调用含窗口服务连接建立，不入计时
    let t0 = DispatchTime.now()
    let changed = engine.pollNow()
    let diffMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
    engine.writePendingNow()  // 手动强制写（正式路径由 1s 防抖触发）

    let uuids = Displays.active().compactMap(\.uuid)
    let key = TransitionalLiveSnapshots.topologyKey(forDisplayUUIDs: uuids)
    print("diff=\(changed ? "changed" : "no-change") 单次差分=\(String(format: "%.2f", diffMs)) ms（04 基线 6.7ms）")
    print("topology-key=\(Displays.topologyIdentity(of: Displays.active()).key)")

    // --watch N：挂起引擎 N 秒，快照 capturedAt 变化即打印
    if let i = args.firstIndex(of: "--watch"), args.count > i + 1,
       let seconds = Double(args[args.index(after: i)]) {
        let formatter = ISO8601DateFormatter()
        print("watch: 引擎挂起 \(seconds)s（2s 轮询 + 1s 防抖 + 启退/屏幕事件加速器）…")
        engine.start()
        let deadline = Date().addingTimeInterval(seconds)
        var lastCapturedAt: Date?
        while Date() < deadline {
            usleep(300_000)
            if let at = store.loadLive(topologyKey: key)?.capturedAt, at != lastCapturedAt {
                print("watch: 快照更新 capturedAt=\(formatter.string(from: at))")
                lastCapturedAt = at
            }
        }
        engine.stop()
    }

    guard let snapshot = store.loadLive(topologyKey: key) else {
        print("snapshot=<未产出>（检查屏幕录制权限：未就绪时 kCGWindowName/title 为 nil，但不阻止组装）")
        return 0
    }
    print("snapshot version=\(snapshot.version) displays=\(snapshot.topology.count) "
        + "spaces=\(snapshot.spaces.count) windows=\(snapshot.windows.count)")
    if let i = args.firstIndex(of: "--out"), args.count > i + 1 {
        let url = URL(fileURLWithPath: args[args.index(after: i)])
        do {
            try SnapshotStore.atomicWrite(try snapshot.encoded(), to: url)
            // 自解析：与 VerifyCLI 同一 Snapshot.decode 路径
            _ = try Snapshot.decode(from: Data(contentsOf: url))
            print("out=\(url.path) parse=ok")
        } catch {
            print("out=FAIL \(error)")
            return 1
        }
    }
        return 0
    }
}
