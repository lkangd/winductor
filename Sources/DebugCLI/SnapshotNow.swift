import Core
import Foundation
import SnapshotEngine

// SnapshotNow.swift — 调试子命令 snapshot-now（票 12；票 03 起引擎只做一次性拍快照，无轮询/落盘）。
// 拍一次快照：打印耗时、拓扑键与快照摘要；--out 把快照写成文件（供 restore / VerifyCLI --snapshot 使用）。
// 保存为预设归票 09。SpaceProviding 以 spaces=nil 构造（降级：spaces=[]、spaceIndex=1）。
// 用法：swift run DebugCLI snapshot-now [--out <文件>]
//   --out   快照写入路径（原子写；缺省不落盘）

enum SnapshotNow {
    // args 已由 main.swift 去除子命令名（票 13 注册表约定）
    static func run(_ args: [String]) -> Int32 {
    let log = FileLogSink(directory: SnapshotStore.defaultLogDirectory, fileName: "debug-snapshot.log")
    let engine = SnapshotEngine(spaces: nil, log: log)

    _ = CGWindowListEnumerator().sample()  // warmup：首次调用含窗口服务连接建立，不入计时
    let t0 = DispatchTime.now()
    let capture: LayoutCapture
    do {
        capture = try engine.capture()
    } catch {
        print("snapshot=<未产出> \(error)")
        return 1
    }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
    let snapshot = capture.snapshot
    print("capture=\(String(format: "%.2f", ms)) ms topology-key=\(capture.topology.identity.key) "
        + "mirrored=\(capture.topology.isMirrored)")
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
