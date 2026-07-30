//
//  NotchAgentApp.swift
//  NotchAgent
//
//  Created by Ziv on 2026/7/30.
//

import SwiftUI
import AppKit

@main
struct NotchAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 岛是 NSPanel、菜单栏项是 NSStatusItem，都在 AppDelegate 里建。
        // 这里必须有一个 Scene，但不该有窗口 —— Settings 是唯一不会自己冒出来的。
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = IslandModel(geometry: ScreenGeometry.main ?? FakeScreenGeometry.macBook14)
    private var controller: IslandWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = IslandWindowController(model: model)
        controller.start()
        self.controller = controller

        installStatusItem()

        // 手动测试用：--args -debugState running|notice|expanded|newtask 直接开在某个形态。
        switch UserDefaults.standard.string(forKey: "debugState") {
        case "newtask": model.beginNewTask()
        case let raw?: IslandState(rawValue: raw).map(model.previewState)
        case nil: break
        }
    }

    /// 用 NSStatusItem 而不是 SwiftUI 的 MenuBarExtra：菜单内容要从 AppDelegate 直接驱动，
    /// 手写 NSMenu 比让 SwiftUI Scene 持有 model 更直接。
    ///
    /// 注意：第三方状态项在 CGWindowList 里由「控制中心」统一合成、报成匿名的 Item-0，
    /// 所以**不能**靠窗口列表里找不到自己的名字就断定图标没建出来 —— 要开关 app 数个数。
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                     accessibilityDescription: "NotchAgent")
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(withTitle: "新建任务…", action: #selector(newTask), keyEquivalent: "n").target = self
        menu.addItem(.separator())

        // 第 1 阶段的手动事件源。第 2 阶段由 StatusFeed 的真实事件取代。
        for (title, selector) in [
            ("新建假会话 refactor-auth", #selector(debugStartA)),
            ("新建假会话 写测试", #selector(debugStartB)),
            ("贴附 ChatGPT", #selector(debugAttach)),
            ("最早的会话开始问你", #selector(debugAsk)),
            ("完成最早的会话", #selector(debugFinish)),
            ("展开", #selector(debugExpand)),
            ("收起", #selector(debugDismiss)),
            ("全部已读", #selector(debugAllRead)),
            ("清空会话", #selector(debugClear)),
        ] {
            menu.addItem(withTitle: title, action: selector, keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 NotchAgent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func newTask() { model.beginNewTask() }
    @objc private func debugStartA() { model.debugStartSession(named: "refactor-auth") }
    @objc private func debugStartB() { model.debugStartSession(named: "写测试") }
    @objc private func debugAttach() { model.debugAttachApp(named: "ChatGPT") }
    @objc private func debugAsk() { model.debugAskOldestRunning() }
    @objc private func debugFinish() { model.debugFinishOldestRunning() }
    @objc private func debugExpand() { model.send(.click) }
    @objc private func debugDismiss() { model.send(.dismiss) }
    @objc private func debugAllRead() { model.send(.allRead) }
    @objc private func debugClear() { model.send(.lastSessionEnded) }
}
