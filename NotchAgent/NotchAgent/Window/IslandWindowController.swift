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
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?

    init(model: IslandModel) {
        self.model = model
        model.onStateChanged = { [weak self] _, next in
            self?.stateDidChange(to: next)
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
            let hosting = NSHostingView(rootView: IslandShell(model: model))
            hosting.autoresizingMask = [.width, .height]
            let panel = NotchWindow(contentView: hosting)
            panel.allowsKeyProvider = { [weak self] in self?.model.state == .expanded }
            window = panel
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
        if isFrontmostAppFullScreen() {
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
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

            // 覆盖整块屏（含菜单栏那条）就认为是全屏。
            if bounds.width >= screen.frame.width - 1, bounds.height >= screen.frame.height - 1 {
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
            window.giveBackFocus()
        }
    }

    private func installEventMonitors() {
        // 点岛外收起。
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.state == .expanded else { return }
                self.model.send(.dismiss)
            }
        }

        // Esc 收起。第 2 阶段终端接上后，Esc 要先给 PTY 当中断，这里会让位。
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            // NSEvent 不是 Sendable，不能穿过隔离边界返回，所以只把「有没有吃掉」传出来。
            var handled = false
            MainActor.assumeIsolated {
                guard let self, self.model.state == .expanded else { return }
                self.model.send(.dismiss)
                handled = true
            }
            return handled ? nil : event
        }
    }

    deinit {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
    }
}
