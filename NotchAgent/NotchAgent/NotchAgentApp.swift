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
        // 岛本身是 NSPanel，不是 WindowGroup。菜单栏项只放调试与设置入口。
        MenuBarExtra("NotchAgent", systemImage: "rectangle.topthird.inset.filled") {
            DebugMenu(model: delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = IslandModel(geometry: ScreenGeometry.main ?? FakeScreenGeometry.macBook14)
    private var controller: IslandWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = IslandWindowController(model: model)
        controller.start()
        self.controller = controller

        // 手动测试用：--args -debugState running|notice|expanded 直接开在某个形态。
        if let raw = UserDefaults.standard.string(forKey: "debugState"),
           let state = IslandState(rawValue: raw) {
            model.previewState(state)
        }
    }
}

/// 第 1 阶段的手动事件源。第 2 阶段由 `StatusFeed` 的真实事件取代。
struct DebugMenu: View {
    @Bindable var model: IslandModel

    var body: some View {
        Text("状态：\(model.state.rawValue)")

        Divider()

        Button("新建会话 refactor-auth") { model.debugStartSession(named: "refactor-auth") }
        Button("新建会话 写测试") { model.debugStartSession(named: "写测试") }
        Button("贴附 ChatGPT") { model.debugAttachApp(named: "ChatGPT") }
        Button("完成最早的会话") { model.debugFinishOldestRunning() }

        Divider()

        Button("展开") { model.send(.click) }
        Button("收起") { model.send(.dismiss) }
        Button("全部已读") { model.send(.allRead) }
        Button("清空会话") { model.send(.lastSessionEnded) }

        Divider()

        Button("退出") { NSApp.terminate(nil) }
    }
}
