import Core
import Foundation
import SnapshotEngine
import SpaceAdapter

// SnapshotNow.swift — 调试子命令 snapshot-now（票 12；display-presets 票 03 起一次性拍快照；display-presets 票 09 起拍完即保存为当前拓扑的预设）。
// 拍一次快照 → PresetStore.addPreset（拓扑无预设时默认自动，spec §4.2）；打印耗时、拓扑键、快照摘要与预设。
// --out 另把快照写成文件（供 VerifyCLI --snapshot 使用）。Space 经 SpaceAdapter 实读（与菜单保存同口径）。
// 用法：swift run DebugCLI snapshot-now [--name <名称>] [--out <文件>]
//   --name  预设名（缺省「MM-dd HH:mm」，与菜单保存输入框默认名同口径）
//   --out   快照另写一份到文件（原子写）
// 退出码：0 = 已保存；1 = 拍快照/保存失败（含镜像中）；2 = 用法错误或名称不可用（撞名/空名）。

enum SnapshotNow {
    static let usage = "usage: swift run DebugCLI snapshot-now [--name <名称>] [--out <文件>]"

    // args 已由 main.swift 去除子命令名（票 13 注册表约定）
    static func run(_ args: [String]) -> Int32 {
        var name: String?
        var outPath: String?
        var i = args.startIndex
        while i < args.endIndex {
            guard args.indices.contains(i + 1) else { print(usage); return 2 }
            switch args[i] {
            case "--name": name = args[i + 1]
            case "--out": outPath = args[i + 1]
            default: print(usage); return 2
            }
            i += 2
        }

        let log = FileLogSink(directory: SnapshotStore.defaultLogDirectory, fileName: "debug-snapshot.log")
        let engine = SnapshotEngine(spaces: SpaceAdapter(log: log), log: log)

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

        if let outPath {
            let url = URL(fileURLWithPath: outPath)
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

        let store = PresetStore(directory: PresetStore.defaultDirectory, log: log)
        do {
            let preset = try store.addPreset(name: name ?? defaultName(), snapshot: snapshot,
                                             topology: capture.topology)
            print("preset 已保存：「\(preset.name)」 id=\(preset.id) auto=\(preset.isAuto) "
                + "topology=\(capture.topology.identity.key)")
            return 0
        } catch PresetStoreError.duplicateName(let taken) {
            print("FAIL: 当前拓扑已有名为「\(taken)」的预设，换个 --name")
            return 2
        } catch PresetStoreError.emptyName {
            print("FAIL: 预设名不能为空")
            return 2
        } catch PresetStoreError.mirrored {
            print("FAIL: 镜像中，无拓扑，不能保存预设（spec §3.3）")
            return 1
        } catch {
            print("FAIL: 保存预设失败：\(error)")
            return 1
        }
    }

    /// 缺省预设名（与 MenubarKit SavePresetFlow 输入框默认名同一定义）
    private static func defaultName() -> String {
        PresetDateFormat.defaultName.formatter().string(from: Date())
    }
}
