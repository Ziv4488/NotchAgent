//
//  ContentArea.swift
//  NotchAgent
//
//  展开态的内容区。第 2 阶段这里换成 SwiftTerm 的终端视图，
//  app tab 则整块不绘制、把真实窗口贴在下面。
//

import SwiftUI

struct ContentArea: View {
    let tab: IslandTab?

    var body: some View {
        Group {
            if let tab, tab.kind == .app {
                // app tab：内容区和输入框整体不绘制，真实窗口贴在 tab 条下方（spec 3.2）。
                Color.clear
            } else {
                transcript
            }
        }
        // 高度由外层 VStack 分配：状态带 / tab 条 / 输入框都是固定高，剩下的全归内容区。
        .frame(maxHeight: .infinity)
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 3) {
            // 第 1 阶段的假数据，照着 states-v2.html 的展开态。
            line("✓", IslandTheme.green, "Edit ", "auth/session.ts", " +34 −12")
            line("✓", IslandTheme.green, "Edit ", "auth/token.ts", " +8 −3")
            line("✓", IslandTheme.green, "Bash ", "", "npm test — 24 passed")
            Spacer(minLength: 8)
            Text("session 已拆成独立模块，测试全过。")
                .foregroundStyle(Color.white.opacity(0.92))
            Spacer(minLength: 0)
        }
        .font(IslandTheme.bodyFont)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(IslandTheme.panelFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(IslandTheme.panelStroke, lineWidth: 0.5)
                }
        }
        .padding(.horizontal, 7)
    }

    private func line(_ mark: String, _ markColor: Color,
                      _ tool: String, _ path: String, _ trailing: String) -> some View {
        HStack(spacing: 0) {
            Text(mark).foregroundStyle(markColor)
            Text("  " + tool).foregroundStyle(Color.white.opacity(0.62))
            Text(path).foregroundStyle(Color(red: 0.48, green: 0.64, blue: 0.97))
            Text(trailing).foregroundStyle(Color.white.opacity(0.3))
        }
    }
}
