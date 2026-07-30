//
//  StatusBand.swift
//  NotchAgent
//
//  顶部状态带。左右分置，中间给物理刘海让路。
//

import SwiftUI

struct StatusBand: View {
    let model: IslandModel
    /// 中间要空出来的宽度 —— 物理刘海占的地方，写不了字。
    let notchGap: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            leading
            Spacer(minLength: notchGap)
            trailing
        }
        .frame(height: height)
        .font(IslandTheme.bandFont)
    }

    @ViewBuilder
    private var leading: some View {
        if model.state != .idle, let tab = model.selectedTab {
            HStack(spacing: 5) {
                StatusDot(status: tab.status)
                // 项目名可能很长。让它截断，绝不能挤掉中间给刘海留的空。
                Text(tab.title)
                    .foregroundStyle(IslandTheme.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 11)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case .running:
            Text("改 session.ts · 2:14")     // 第 2 阶段换成真实动作 + 计时
                .foregroundStyle(IslandTheme.dim)
                .monospacedDigit()
                .padding(.trailing, 11)
                .fixedSize()
        case .notice, .expanded:
            Button {
                model.send(.dismiss)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(IslandTheme.dim)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
    }
}

/// 会话状态的小圆点：绿＝完成，黄＝在跑，灰＝已结束。
struct StatusDot: View {
    let status: IslandTab.Status

    private var color: Color {
        switch status {
        case .running: IslandTheme.amber
        case .done: IslandTheme.green
        case .ended: Color.white.opacity(0.3)
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .shadow(color: color.opacity(0.85), radius: 3)
    }
}
