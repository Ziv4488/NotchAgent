//
//  NotchAgentApp.swift
//  NotchAgent
//
//  Created by Ziv on 2026/7/30.
//

import SwiftUI

@main
struct NotchAgentApp: App {
    var body: some Scene {
        // 第 1 阶段会把这里换成菜单栏项 + NotchWindow，岛本身不是 WindowGroup。
        WindowGroup {
            PlaceholderView()
        }
    }
}

/// 占位视图 —— 第 1.5 步换成真正的岛。
struct PlaceholderView: View {
    var body: some View {
        Text("NotchAgent")
            .font(.title2)
            .foregroundStyle(.secondary)
            .frame(width: 320, height: 160)
    }
}
