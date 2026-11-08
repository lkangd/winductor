import ApplicationServices
import Darwin
import Foundation

// MinimalAXReader.swift — 票 12 自含的最小公开 AX 读取器（spec §7.5：
// AX 仅出现在落盘路径——对离屏 layer-0 候选读 AXMinimized、frame==整屏候选读 AXFullScreen）。
// ⚠️ 票 13 的 AXFacade（_AXUIElementGetWindow 配对 + 属性读写门面）并行开发中；
//    本文件自含 ≈20 行最小实现，票 14 接线 AXFacade 后由其整体替代并删除本文件。
// 写法照 05 spike / VerifyCLI：dlsym 取 _AXUIElementGetWindow，wid == CGWindowNumber。

/// 一次 AX 探测结果（按候选窗口逐个查询，写盘路径个位数次）
public struct WindowAXState: Sendable {
    public let minimized: Bool
    public let fullScreen: Bool
    public init(minimized: Bool, fullScreen: Bool) {
        self.minimized = minimized
        self.fullScreen = fullScreen
    }
}

/// AX 探测接缝：拍快照组装与恢复实况收集按需调用（CG 采样本身零 AX）；测试注入 FakeAXProber 计数调用。
public protocol WindowAXProbing: Sendable {
    func probe(pid: Int32, windowID: UInt32) -> WindowAXState
}

/// 最小公开 AX 读取器（票 14 接线 AXFacade 后替代）
public struct MinimalAXReader: WindowAXProbing {
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

    private let getWindow: GetWindowFn?

    public init() {
        getWindow = [
            "/System/Library/PrivateFrameworks/HIServices.framework/HIServices",
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            "",
        ].lazy.compactMap { Self.loadSym($0, "_AXUIElementGetWindow", as: GetWindowFn.self) }.first
    }

    public func probe(pid: Int32, windowID: UInt32) -> WindowAXState {
        guard let getWindow, pid > 0 else { return WindowAXState(minimized: false, fullScreen: false) }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &value) == .success else {
            return WindowAXState(minimized: false, fullScreen: false)
        }
        for element in (value as? NSArray ?? []).compactMap({ $0 as! AXUIElement? }) {
            var wid: UInt32 = 0
            guard getWindow(element, &wid) == .success, wid == windowID else { continue }
            return WindowAXState(minimized: Self.boolAttr(element, "AXMinimized"),
                                 fullScreen: Self.boolAttr(element, "AXFullScreen"))
        }
        return WindowAXState(minimized: false, fullScreen: false)
    }

    private static func boolAttr(_ el: AXUIElement, _ name: String) -> Bool {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success,
              CFGetTypeID(v!) == CFBooleanGetTypeID() else { return false }
        return CFEqual(v!, kCFBooleanTrue)
    }

    private static func loadSym<T>(_ lib: String, _ name: String, as type: T.Type) -> T? {
        let h = lib.isEmpty ? dlopen(nil, RTLD_LAZY) : dlopen(lib, RTLD_LAZY)
        guard let hh = h, let p = dlsym(hh, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }
}
