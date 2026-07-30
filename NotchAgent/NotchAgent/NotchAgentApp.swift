//
//  NotchAgentApp.swift
//  NotchAgent
//
//  Created by Ziv on 2026/7/30.
//

import SwiftUI

@main
struct NotchAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            SpikeControlView()
                .frame(minWidth: 560, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}

/// LSUIElement 的 app 默认不会自己激活，探针阶段需要能看到并操作控制面板。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
