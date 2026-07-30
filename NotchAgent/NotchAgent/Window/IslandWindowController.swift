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
            panel.allowsKeyProvider = { [weak self] in self?.model.state == .expanded }
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
                MainActor.assumeIsolated { self?.updateVisibility() }
            }
        }
    }

    /// 前台 app 全屏时刘海区被系统占用，岛让位（spec 3.4）。
    private func updateVisibility() {
        guard let window else { return }
        let shouldHide = isFrontmostAppFullScreen()

        if shouldHide != isHiddenForFullScreen {
            isHiddenForFullScreen = shouldHide
            if shouldHide { window.orderOut(nil) } else { window.orderFrontRegardless() }
        } else if !shouldHide, !window.isVisible {
            window.orderFrontRegardless()
        }

        // 进出全屏有约一秒的动画，通知到达时窗口尺寸还没稳定，判断会不准。
        // 藏起来之后就轮询，直到确认能出来为止 —— 否则退出全屏后岛回不来。
        if shouldHide, visibilityTimer == nil {
            visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateVisibility() }
            }
        } else if !shouldHide {
            visibilityTimer?.invalidate()
            visibilityTimer = nil
        }
    }

    private func isFrontmostAppFullScreen() -> Bool {
        guard let screen = NSScreen.main,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return false }

        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in listed {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid == app.processIdentifier,
                  // layer 0 是普通应用窗口，排除掉浮层和面板。
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let raw = entry[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: raw as! CFDictionary)
            else { continue }

            // 全屏窗口连菜单栏那条一起盖住，普通的"最大化"盖不到 —— 用这个区分。
            // 窗口坐标原点在左上，所以 minY == 0 才是真的顶到屏幕上沿。
            if bounds.minY <= 0,
               bounds.width >= screen.frame.width - 1,
               bounds.height >= screen.frame.height - 1 {
                return true
            }
        }
        return false
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
        // 收起只由 ✕ 与 Esc 触发，都是明确动作。

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEscape = event.keyCode == 53
            let isShiftTab = event.keyCode == 48 && event.modifierFlags.contains(.shift)
            guard isEscape || isShiftTab else { return event }

            // NSEvent 不是 Sendable，不能穿过隔离边界返回，所以只把「有没有吃掉」传出来。
            var handled = false
            MainActor.assumeIsolated {
                guard let self, self.model.state == .expanded else { return }
                if isShiftTab {
                    // 第 2 阶段终端接上后，⇧Tab 应当原样喂给 PTY、由 Claude Code 自己切；
                    // 现在先在岛内切，把这个键位占住不让别人抢走。
                    self.model.cycleMode()
                } else if self.model.isComposingNewTask, !self.model.tabs.isEmpty {
                    // Esc 先取消新建流程，再按一次才收起岛。
                    // 第 2 阶段终端接上后，Esc 要先给 PTY 当中断，这里会再让位。
                    self.model.cancelNewTask()
                } else {
                    self.model.send(.dismiss)
                }
                handled = true
            }
            return handled ? nil : event
        }
    }

    deinit {
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
    }
}
