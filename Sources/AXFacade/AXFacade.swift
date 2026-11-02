import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// AXFacade.swift — AX 门面（票 13 拥有本文件，spec §10.1）。
// 职责：AXPosition / AXSize / AXMinimized / AXFullScreen 读写、
//       _AXUIElementGetWindow 配对（dlsym 三级回退，照 05 spike 实测写法）。
// 错误纪律：无辅助功能权限（AXError.apiDisabled）返回明确错误，绝不崩溃。

/// AX 操作失败的明确错误（spec §10.2：无权限不崩溃）
public enum AXFacadeError: Error, Equatable, Sendable {
    /// 辅助功能权限缺失（AXError.apiDisabled）
    case apiDisabled
    /// 系统层失败（AXError.cannotComplete，常见于目标 app 忙/挂起）
    case cannotComplete
    /// 元素或属性不支持（AXError.attributeUnsupported / .noAttribute / .noValue）
    case elementUnsupported
    /// 元素已失效（AXError.elementInvalid / .cannotComplete 伴随窗口关闭）
    case elementInvalid
    /// 其他 AXError 原码
    case failure(code: Int32)
}

public enum AXFacade {
    // MARK: - _AXUIElementGetWindow 配对（私有稳路径，spec §5.1：实测 29/29）

    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError

    /// dlsym 三级回退（照 spike：HIServices → ApplicationServices → 主程序镜像）
    private static let getWindowFn: AXGetWindowFn? = {
        let libs = [
            "/System/Library/PrivateFrameworks/HIServices.framework/HIServices",
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            "",
        ]
        for lib in libs {
            let h = lib.isEmpty ? dlopen(nil, RTLD_LAZY) : dlopen(lib, RTLD_LAZY)
            guard let hh = h, let p = dlsym(hh, "_AXUIElementGetWindow") else { continue }
            return unsafeBitCast(p, to: AXGetWindowFn.self)
        }
        return nil
    }()

    /// 辅助功能权限是否已授予（未授予时全部读写抛 apiDisabled）
    public static func isProcessTrusted() -> Bool { AXIsProcessTrusted() }

    /// _AXUIElementGetWindow 是否可加载（配对能力的启动探针）
    public static func isPairingAvailable() -> Bool { getWindowFn != nil }

    /// AXUIElement → CGWindowID（kCGWindowNumber）。失败抛明确错误。
    public static func windowID(of element: AXUIElement) throws -> UInt32 {
        guard let f = getWindowFn else { throw AXFacadeError.elementUnsupported }
        var wid: UInt32 = 0
        let err = f(element, &wid)
        guard err == .success else { throw map(err) }
        return wid
    }

    // MARK: - 元素枚举

    /// 某 app 的全部 AX 窗口元素（AXWindows 属性）。
    public static func windows(ofApplication pid: pid_t) throws -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &value)
        guard err == .success else { throw map(err) }
        guard let array = value as? NSArray else { throw AXFacadeError.elementUnsupported }
        return array.map { $0 as! AXUIElement }
    }

    /// CGWindowID → AX 元素反查（遍历运行中 app 配对；全屏后台窗口 AX 不可见会返回 nil，spike #4 实测）。
    public static func findWindow(withWindowID wid: UInt32) -> AXUIElement? {
        for app in NSWorkspace.shared.runningApplications
        where app.processIdentifier > 0 && app.activationPolicy != .prohibited {
            guard let wins = try? windows(ofApplication: app.processIdentifier) else { continue }
            for w in wins where (try? windowID(of: w)) == wid { return w }
        }
        return nil
    }

    /// 一次遍历建 windowID → AX 元素索引（L1 批量摆位用；逐窗全量遍历实测 105s，索引后秒级）。
    /// timeoutPerApp：给每个 app 元素设消息超时（秒），防止单 app 卡顿拖住整轮。
    public static func makeWindowIndex(timeoutPerApp: Float? = nil) -> [UInt32: AXUIElement] {
        var index: [UInt32: AXUIElement] = [:]
        for app in NSWorkspace.shared.runningApplications
        where app.processIdentifier > 0 && app.activationPolicy != .prohibited {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            if let t = timeoutPerApp {
                AXUIElementSetMessagingTimeout(appElement, t)
            }
            guard let wins = try? windows(ofApplication: app.processIdentifier) else { continue }
            for w in wins {
                if let wid = try? windowID(of: w) { index[wid] = w }
            }
        }
        return index
    }

    // MARK: - 几何读写（AXPosition / AXSize）

    public static func position(of element: AXUIElement) throws -> CGPoint {
        try axValue(element, attribute: "AXPosition", type: .cgPoint)
    }

    public static func setPosition(_ element: AXUIElement, _ point: CGPoint) throws {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { throw AXFacadeError.elementUnsupported }
        try set(element, attribute: "AXPosition", value: v)
    }

    public static func size(of element: AXUIElement) throws -> CGSize {
        try axValue(element, attribute: "AXSize", type: .cgSize)
    }

    public static func setSize(_ element: AXUIElement, _ size: CGSize) throws {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { throw AXFacadeError.elementUnsupported }
        try set(element, attribute: "AXSize", value: v)
    }

    // MARK: - 状态读写（AXMinimized / AXFullScreen）

    public static func isMinimized(of element: AXUIElement) throws -> Bool {
        try boolAttribute(element, attribute: "AXMinimized")
    }

    public static func setMinimized(_ element: AXUIElement, _ minimized: Bool) throws {
        try setBool(element, attribute: "AXMinimized", value: minimized)
    }

    public static func isFullScreen(of element: AXUIElement) throws -> Bool {
        try boolAttribute(element, attribute: "AXFullScreen")
    }

    public static func setFullScreen(_ element: AXUIElement, _ fullScreen: Bool) throws {
        try setBool(element, attribute: "AXFullScreen", value: fullScreen)
    }

    // MARK: - 内部助手

    private static func copy(_ element: AXUIElement, attribute: String) throws -> CFTypeRef {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { throw map(err) }
        return try value ?? { throw AXFacadeError.elementUnsupported }()
    }

    private static func set(_ element: AXUIElement, attribute: String, value: CFTypeRef) throws {
        let err = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        guard err == .success else { throw map(err) }
    }

    private static func boolAttribute(_ element: AXUIElement, attribute: String) throws -> Bool {
        let v = try copy(element, attribute: attribute)
        guard CFGetTypeID(v) == CFBooleanGetTypeID() else { throw AXFacadeError.elementUnsupported }
        return CFEqual(v, kCFBooleanTrue)
    }

    private static func setBool(_ element: AXUIElement, attribute: String, value: Bool) throws {
        try set(element, attribute: attribute, value: value ? kCFBooleanTrue : kCFBooleanFalse)
    }

    private static func axValue(_ element: AXUIElement, attribute: String, type: AXValueType) throws -> CGPoint {
        let v = try copy(element, attribute: attribute)
        guard CFGetTypeID(v) == AXValueGetTypeID() else { throw AXFacadeError.elementUnsupported }
        var out = CGPoint.zero
        guard AXValueGetValue(v as! AXValue, type, &out) else { throw AXFacadeError.elementUnsupported }
        return out
    }

    private static func axValue(_ element: AXUIElement, attribute: String, type: AXValueType) throws -> CGSize {
        let v = try copy(element, attribute: attribute)
        guard CFGetTypeID(v) == AXValueGetTypeID() else { throw AXFacadeError.elementUnsupported }
        var out = CGSize.zero
        guard AXValueGetValue(v as! AXValue, type, &out) else { throw AXFacadeError.elementUnsupported }
        return out
    }

    private static func map(_ err: AXError) -> AXFacadeError {
        switch err {
        case .success: return .failure(code: AXError.success.rawValue)
        case .apiDisabled: return .apiDisabled
        case .cannotComplete: return .cannotComplete
        case .invalidUIElement, .invalidUIElementObserver: return .elementInvalid
        case .attributeUnsupported, .noValue, .actionUnsupported, .parameterizedAttributeUnsupported, .notImplemented:
            return .elementUnsupported
        default: return .failure(code: err.rawValue)
        }
    }
}
