import CoreGraphics
import Darwin
import Foundation

// TopologyScreensLive.swift — 拓扑身份的实况输入（公开 API 读屏）。纯判定在 TopologyIdentity.swift。
// 无稳定 UUID 的屏不参与拓扑（与快照/恢复的屏归属口径一致）。

extension Displays {
    /// 当前活动屏 → 拓扑输入（UUID、名称、frame、像素分辨率、旋转、是否在镜像集合）
    public static func topologyScreens(_ infos: [Info] = active()) -> [TopologyScreen] {
        infos.compactMap { info in
            guard let uuid = info.uuid, !uuid.isEmpty else { return nil }
            let mode = CGDisplayCopyDisplayMode(info.id)
            return TopologyScreen(
                uuid: uuid,
                name: localizedName(for: info.id),
                frame: info.bounds,
                pixelWidth: mode?.pixelWidth ?? Int(CGDisplayPixelsWide(info.id)),
                pixelHeight: mode?.pixelHeight ?? Int(CGDisplayPixelsHigh(info.id)),
                rotation: rotation(for: info.id),
                isMirrored: CGDisplayIsInMirrorSet(info.id) != 0)
        }
    }

    /// 活动屏信息 → 拓扑身份（只取身份要素：UUID、frame、旋转；不读屏名/分辨率）。
    /// 无稳定 UUID 的屏不参与。rotation 可注入（恢复引擎测试桩）。
    public static func topologyIdentity(of infos: [Info],
                                        rotation: (CGDirectDisplayID) -> Int = Displays.rotation(for:)) -> TopologyIdentity {
        TopologyIdentity(screens: infos.compactMap { info in
            guard let uuid = info.uuid, !uuid.isEmpty else { return nil }
            return TopologyScreen(uuid: uuid, name: "", frame: info.bounds, pixelWidth: 0, pixelHeight: 0,
                                  rotation: rotation(info.id), isMirrored: false)
        })
    }

    /// 屏幕名：dlsym 取 CGDisplayGetName（Swift 不直接导出），失败回退 "Display <id>"
    public static func localizedName(for id: CGDirectDisplayID) -> String {
        displayNameFn(id) as String? ?? "Display \(id)"
    }

    private static let displayNameFn: @convention(c) (UInt32) -> CFString? = {
        for lib in ["/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", ""] {
            let h = lib.isEmpty ? dlopen(nil, RTLD_LAZY) : dlopen(lib, RTLD_LAZY)
            guard let hh = h, let p = dlsym(hh, "CGDisplayGetName") else { continue }
            return unsafeBitCast(p, to: (@convention(c) (UInt32) -> CFString?).self)
        }
        return { _ in nil }
    }()
}

extension ObservedTopology {
    /// 当前实况拓扑
    public static func current() -> ObservedTopology {
        ObservedTopology(screens: Displays.topologyScreens())
    }
}
