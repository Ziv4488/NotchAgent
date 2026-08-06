//
//  AXBridging.swift
//  NotchAgent
//
//  岛用得到的全部辅助功能（AX）能力，收在一个协议后面（plan 3.2）。
//

import AppKit
import ApplicationServices

/// 一个窗口在 AX 那边的句柄。
///
/// 真实实现里包着 `AXUIElement`，假实现里就是个编号。**外面不许拆开看** ——
/// 岛这边关心的只有「这是哪一个窗口」，拆开就等于把 AX 漏到了业务层。
protocol AXWindowHandle: AnyObject {}

/// 抽成协议**只为了能测**。
///
/// 贴附这条路上真正容易写错的三件事 —— 调用超时、原始 frame 的记录与还原、
/// 目标 app 没跑时的启动等待 —— 都是「出岔子才走到」的分支，真机上没法可靠地
/// 造出来：你没法让 ChatGPT 按需卡住五秒。塞个假实现进来就都能离线测了。
///
/// 真机行为靠 `docs/manual-tests.md` 的手测清单守。
protocol AXBridging {
    /// 有没有辅助功能授权。**没有的话下面每一个方法都会静默返回 nil**
    /// （不是报错），所以调用方必须先问这个（spec 11.4 踩过）。
    var isTrusted: Bool { get }

    func isRunning(bundleID: String) -> Bool
    /// 拉起 app。已经在跑就什么都不做。
    func launch(bundleID: String)
    func activate(bundleID: String)
    func hide(bundleID: String)
    func unhide(bundleID: String)

    /// 目标 app 当前的前台窗口。app 没跑、或者一个窗口都没有时返回 nil。
    ///
    /// **每次都重新解析而不是记住一个句柄**：用户在 app 里 ⌘` 换了窗口，
    /// 岛要跟着换贴附对象（08-06 定的形态，一个 app 一个 tab）。
    func focusedWindow(bundleID: String) -> AXWindowHandle?

    /// 这两个句柄指的是不是同一个窗口。
    ///
    /// 由桥来判而不是让句柄自己 `Equatable`：每次解析都会包出一个**新的**
    /// `AXWindow` 对象，按对象身份比一律不相等，而 `AXUIElement` 自己有
    /// `CFEqual` 语义。账本按窗口记（见 `WindowAttach.ledger`），比错了
    /// 就会给同一个窗口记两笔原始 frame，还回去的是错的那份。
    func isSameWindow(_ a: AXWindowHandle, _ b: AXWindowHandle) -> Bool

    func frame(of window: AXWindowHandle) -> CGRect?

    /// 设进去，返回**实得**的 frame。
    ///
    /// 返回实得值而不是成功与否：AX 会按目标窗口的最小尺寸钳制，而**最小尺寸
    /// 根本问不出来** —— 窗口只暴露 `AXPosition` / `AXSize` 两个可写属性，
    /// 没有 `AXMinValue`（spec 11.4 实测）。唯一的办法就是设完读回，
    /// 拿实得值反过来钉住岛自己的拖拽下限。
    @discardableResult
    func setFrame(_ frame: CGRect, of window: AXWindowHandle) -> CGRect?
}

// MARK: - 真实实现

final class AXWindow: AXWindowHandle {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}

/// 直接打 ApplicationServices 的那一版。**所有方法都可能阻塞**，
/// 调用方负责把它们放到后台队列上（见 `WindowAttach`）。
struct SystemAXBridge: AXBridging {
    /// 单次 AX 往返的上限。
    ///
    /// spec 11.4 实测：中位数 0.24–4.2ms，p95 6.6–9.7ms，但 `AXSize` 撞到过
    /// 一次 520ms。1 秒是「目标 app 真的卡住了」和「只是慢了一下」之间的分界，
    /// 取得比最坏观测值宽一个数量级，免得把正常的抖动判成失败。
    static let messagingTimeout: Float = 1.0

    var isTrusted: Bool { AXIsProcessTrusted() }

    func isRunning(bundleID: String) -> Bool { runningApp(bundleID) != nil }

    func launch(bundleID: String) {
        guard !isRunning(bundleID: bundleID),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    func activate(bundleID: String) { runningApp(bundleID)?.activate() }
    func hide(bundleID: String) { runningApp(bundleID)?.hide() }
    func unhide(bundleID: String) { runningApp(bundleID)?.unhide() }

    func focusedWindow(bundleID: String) -> AXWindowHandle? {
        guard let app = runningApp(bundleID) else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, Self.messagingTimeout)

        // 先问 AXFocusedWindow —— 那才是用户此刻在用的那个。
        if let focused = copy(axApp, kAXFocusedWindowAttribute) {
            return AXWindow(focused as! AXUIElement)
        }
        // 退而求其次：窗口列表里标着 AXMain 的，再不行拿第一个。
        guard let list = copy(axApp, kAXWindowsAttribute) as? [AXUIElement], !list.isEmpty else {
            return nil
        }
        let main = list.first { (copy($0, kAXMainAttribute) as? Bool) == true }
        return AXWindow(main ?? list[0])
    }

    func isSameWindow(_ a: AXWindowHandle, _ b: AXWindowHandle) -> Bool {
        guard let a = (a as? AXWindow)?.element, let b = (b as? AXWindow)?.element else { return false }
        return CFEqual(a, b)
    }

    func frame(of window: AXWindowHandle) -> CGRect? {
        guard let element = (window as? AXWindow)?.element,
              let position = value(element, kAXPositionAttribute, .cgPoint, CGPoint.zero),
              let size = value(element, kAXSizeAttribute, .cgSize, CGSize.zero) else { return nil }
        return CGRect(origin: position, size: size)
    }

    @discardableResult
    func setFrame(_ frame: CGRect, of window: AXWindowHandle) -> CGRect? {
        guard let element = (window as? AXWindow)?.element else { return nil }
        // **先尺寸后位置。** 反过来的话，窗口被钳制在最小尺寸时会以左上角为锚点
        // 往右下溢出，位置就白设了。
        var size = frame.size
        if let v = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, v)
        }
        var origin = frame.origin
        if let v = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, v)
        }
        return self.frame(of: window)
    }

    // MARK: -

    private func runningApp(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success ? out : nil
    }

    private func value<T>(_ element: AXUIElement, _ attribute: String,
                          _ type: AXValueType, _ empty: T) -> T? {
        guard let raw = copy(element, attribute) else { return nil }
        var out = empty
        guard AXValueGetValue(raw as! AXValue, type, &out) else { return nil }
        return out
    }
}
