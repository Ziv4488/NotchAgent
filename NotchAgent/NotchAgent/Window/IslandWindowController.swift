//
//  IslandWindowController.swift
//  NotchAgent
//
//  把岛挂到屏幕上，并盯住屏幕几何、全屏、焦点这几件 AppKit 的事。
//

import AppKit
import SwiftUI

@MainActor
final class IslandWindowController {

    private let model: IslandModel
    private var window: NotchWindow?
    private var hostingView: NotchHostingView?
    private var localKeyMonitor: Any?
    private var visibilityTimer: Timer?
    private var isHiddenForFullScreen = false
    /// 环境变动后的观察窗口。这段时间里反复确认，动画结束前的读数不可信。
    private var settleDeadline: Date?

    init(model: IslandModel) {
        self.model = model
        model.onStateChanged = { [weak self] _, next in
            self?.stateDidChange(to: next)
        }
        // 拖拽调整展开尺寸时，承载岛的面板也得跟着长大，否则岛会被窗口边界切掉。
        // 拖拽期间没有动画，逐帧 setFrame 是跟手的，不会像状态切换那样抖。
        model.onExpandedSizeChanged = { [weak self] in
            guard let self, let window = self.window else { return }
            window.setFrame(self.model.metrics.containerFrame, display: true)
        }
        // 收起态那个输入框用完了。展开态不还 —— 那时候键盘本来就该在岛上。
        model.onInlineEntryEnded = { [weak self] in
            guard let self, self.model.state != .expanded else { return }
            self.window?.giveBackFocus()
        }
        model.onInlineEntryFocusRequested = { [weak self] in
            self?.window?.claimKeyboard()
        }
    }

    // MARK: - 生命周期

    func start() {
        rebuild()
        observeEnvironment()
        installEventMonitors()
    }

    /// 重新测量几何并重建窗口。屏幕变化、睡眠唤醒都走这里。
    func rebuild() {
        guard let geometry = ScreenGeometry.main else {
            window?.orderOut(nil)
            return
        }
        model.geometry = geometry

        if window == nil {
            let hosting = NotchHostingView(rootView: IslandShell(model: model))
            hosting.autoresizingMask = [.width, .height]
            hosting.islandGeometry = { [model] in (model.size, model.cornerRadii) }
            let panel = NotchWindow(contentView: hosting)
            // 收起态平时拿不了键盘（spec 11.2）。唯一的例外是岛下面那个浮层
            // 变成了输入框：终端在等一段自由输入，用户点了框就该能直接打字，
            // 不必先把岛展开。见 `IslandModel.wantsInlineTextEntry`。
            panel.allowsKeyProvider = { [weak self] in
                guard let self else { return false }
                return self.model.state == .expanded || self.model.wantsInlineTextEntry
            }
            window = panel
            hostingView = hosting
        }

        window?.setFrame(model.metrics.containerFrame, display: true)
        updateVisibility()
    }

    // MARK: - 环境监听

    private func observeEnvironment() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        // 全屏 app 独占一个 Space，切 Space 与切前台 app 都要重判。
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.beginSettling() }
            }
        }

        // 展开期间用户自己点去了别的 app —— 收起时就不该再把焦点抢回来。
        // 盯**事件**而不是收起那一刻的 `NSApp.isActive`：后者试过，实机上不成立。
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                              object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isSelf = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            let name = app?.bundleIdentifier ?? app?.localizedName ?? "未知"
            MainActor.assumeIsolated {
                guard let self, !isSelf else { return }
                self.window?.forgetFocusHandoff(because: name)
            }
        }
    }

    /// 当前 Space 被全屏窗口占据时刘海区归系统，岛让位（spec 3.4）。
    private func updateVisibility() {
        guard let window else { return }
        let shouldHide = isCurrentSpaceFullScreen()

        if shouldHide != isHiddenForFullScreen {
            isHiddenForFullScreen = shouldHide
            if shouldHide {
                // 展开态是抢着焦点的。直接 orderOut 会留下一个看不见却仍是 key 的窗口，
                // 键盘事件继续进岛。先收起，焦点顺着 stateDidChange 还给原来那个 app。
                if model.state == .expanded { model.send(.dismiss) }
                window.orderOut(nil)
            } else {
                window.orderFrontRegardless()
            }
        } else if !shouldHide, !window.isVisible {
            window.orderFrontRegardless()
        }

        // 进出全屏、切 Space 都有约一秒的动画，通知到达时窗口尺寸还没稳定，判断会不准。
        // 所以不只在藏起来之后轮询：任何环境变动之后都多看几眼，直到局面稳定。
        let settling = settleDeadline.map { Date() < $0 } ?? false
        if shouldHide || settling {
            if visibilityTimer == nil {
                visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateVisibility() }
                }
            }
        } else {
            visibilityTimer?.invalidate()
            visibilityTimer = nil
            settleDeadline = nil
        }
    }

    /// 环境刚动过，接下来几秒的判断都不可信，得反复确认。
    private func beginSettling() {
        settleDeadline = Date().addingTimeInterval(3)
        updateVisibility()
    }

    /// 当前 Space 上有没有全屏窗口。
    ///
    /// **不能靠 `frontmostApplication` 判断**：岛展开时会抢焦点，前台 app 就是我们自己，
    /// 于是「前台 app 是不是全屏」永远为假，展开的岛切进全屏 Space 后就赖着不走。
    /// `.optionOnScreenOnly` 返回的本来就只是当前 Space 的窗口，直接扫它更准也更简单。
    private func isCurrentSpaceFullScreen() -> Bool {
        guard let screen = NSScreen.main else { return false }
        let me = ProcessInfo.processInfo.processIdentifier

        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in listed {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  // layer 0 是普通应用窗口，排除掉浮层和面板。
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let raw = entry[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: raw as! CFDictionary)
            else { continue }

            if Self.isFullScreenBounds(bounds, screenSize: screen.frame.size,
                                       menuBarHeight: Self.menuBarInset(of: screen)) { return true }
        }
        return false
    }

    /// 屏幕顶部被菜单栏占掉多少。
    ///
    /// **不用 `safeAreaInsets.top`**：那个只在有刘海的机器上非零，无刘海屏返回 0，
    /// 而那些机器上菜单栏照样占着 24pt。`frame.maxY - visibleFrame.maxY` 两边都对，
    /// 而且实测在**全屏 Space 里也一样**（Dock 的 inset 会消失，菜单栏那条不会）。
    static func menuBarInset(of screen: NSScreen) -> CGFloat {
        max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// 一个窗口的 bounds 算不算全屏。
    ///
    /// **原来的判据（`minY <= 0 && height >= 屏高 - 1`）在刘海机上从来没成立过。**
    /// 2026-08-02 拿一个真的 `toggleFullScreen` 窗口实测（探针见提交记录）：
    ///
    /// | 状态 | 那个窗口的 bounds | `visibleFrame` |
    /// |---|---|---|
    /// | 普通最大化 | `0,33 1512x901` | `(0,48,1512,901)` |
    /// | **真全屏** | `0,33 1512x949` | `(0,0,1512,949)` |
    ///
    /// 刘海机上全屏窗口**也不盖菜单栏那 33pt** —— 系统把那一条留给自己。
    /// 于是 `minY` 恒为 33、`height` 恒为 949，判据永远为假，岛在全屏 app 上
    /// 一直赖着不走。用户 2026-08-02 直接甩了张截图过来：全屏着，岛还在上面。
    ///
    /// 真正的区分点是**下沿**：全屏窗口一直铺到屏幕最底、把 Dock 那一条也吃掉；
    /// 最大化的窗口停在 Dock 上面（Dock 自动隐藏时也还差那 4pt 的热区）。
    /// Dock 摆在左右两侧时最大化窗口的**宽度**又不够，同样漏不过去。
    ///
    /// `bounds` 来自 `CGWindowList`，坐标原点在**左上**。
    static func isFullScreenBounds(_ bounds: CGRect, screenSize: CGSize,
                                   menuBarHeight: CGFloat) -> Bool {
        bounds.width >= screenSize.width - 1
            // 顶：要么顶到上沿（无刘海），要么紧贴在菜单栏那一条下面（有刘海）。
            && bounds.minY <= menuBarHeight + 2
            // 底：必须真的铺到屏幕最底 —— 这一条才是和「最大化」的分界线。
            && bounds.maxY >= screenSize.height - 1
    }

    // MARK: - 焦点与收起

    private func stateDidChange(to next: IslandState) {
        guard let window else { return }
        if next == .expanded {
            // 展开必须抢焦点，否则键盘事件根本到不了岛（spec 11.2）。
            window.takeFocus()
        } else {
            model.isComposingNewTask = false
            window.giveBackFocus()
        }
    }

    private func installEventMonitors() {
        // 这里**不装**"点岛外就收起"的全局监听。
        // 展开时要能从访达把文件夹拖进岛（spec 3.3），一点别处就收起会让拖拽根本没法完成。
        // 收起只由 ✕ 与 ⌘W 触发，都是明确动作。

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags

            // NSEvent 不是 Sendable，不能穿过隔离边界返回，所以只把「有没有吃掉」传出来。
            var handled = false
            MainActor.assumeIsolated {
                guard let self, self.model.state == .expanded else { return }
                // 一个 tab 都没有时新建表单是唯一能显示的东西，退不出去 —— 那时 Esc 也别吃。
                let canCancel = self.model.isComposingNewTask && !self.model.tabs.isEmpty
                switch Self.action(keyCode: keyCode, modifiers: modifiers,
                                   canCancelNewTask: canCancel) {
                case .dismiss:
                    self.model.send(.dismiss)
                    handled = true
                case .cancelNewTask:
                    self.model.cancelNewTask()
                    handled = true
                case .passThrough:
                    break
                }
            }
            return handled ? nil : event
        }
    }

    /// 展开态下一次按键的归属。
    enum KeyAction: Equatable {
        /// 岛吃掉，收起。
        case dismiss
        /// 岛吃掉，退出新建流程。
        case cancelNewTask
        /// 岛不管，原样往下传 —— 绝大多数按键走这条。
        case passThrough
    }

    /// 岛在展开态要不要截下这个键。
    ///
    /// **Esc 和 ⇧Tab 一律放行给终端。** 它们在 Claude Code 里都有确切含义：
    /// Esc 取消选单、中断当前回合、连按两下退回上一条；⇧Tab 切权限模式。
    /// 岛在中间拦一道，等于把这些功能整个废掉 —— 屏幕上明明写着「Esc to cancel」，
    /// 按下去却是岛收起来了。收起改用 ⌘W：语义正是「关掉这个面板」，
    /// 而终端和 Claude Code 都不占这个键。
    ///
    /// 唯一的例外是新建表单：那时候 first responder 是 SwiftUI 的输入框，
    /// 根本没有终端在接键，Esc 退出表单不抢任何人的东西。
    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                       canCancelNewTask: Bool) -> KeyAction {
        // 只看这四个真正参与组合键的修饰键。
        // **不能用 `.deviceIndependentFlagsMask`** —— caps lock、fn、数字小键盘
        // 都在那个掩码里，帽子键一开 `flags == .command` 就不成立，⌘W 静悄悄失灵。
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        if keyCode == KeyCode.w, flags == .command { return .dismiss }
        if keyCode == KeyCode.escape, flags.isEmpty, canCancelNewTask { return .cancelNewTask }
        return .passThrough
    }

    enum KeyCode {
        static let w: UInt16 = 13
        static let escape: UInt16 = 53
    }

    deinit {
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
    }
}
