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

    // MARK: - 左侧：身份

    @ViewBuilder
    private var leading: some View {
        HStack(spacing: 5) {
            if let tab = model.selectedTab {
                StatusDot(status: tab.status)
                // 项目名可能很长。让它截断，绝不能挤掉中间给刘海留的空。
                Text(tab.title)
                    .foregroundStyle(IslandTheme.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if model.state == .expanded {
                // 一个会话都没有时，展开态落在新建流程上，状态带说清楚这件事。
                Text("新建任务").foregroundStyle(IslandTheme.dim)
            } else {
                // 连历史会话都没有：空心点 + app 名，让岛在闲着时也有身份。
                Circle()
                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
                    .frame(width: 5, height: 5)
                Text("NotchAgent").foregroundStyle(IslandTheme.faint)
            }
        }
        .padding(.leading, 11)
    }

    // MARK: - 右侧：进度或计数

    @ViewBuilder
    private var trailing: some View {
        switch model.state {
        case .idle:
            if !model.tabs.isEmpty {
                Text("\(model.tabs.count) 个会话")
                    .foregroundStyle(IslandTheme.faint)
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.trailing, 11)
            }
        case .running:
            Text("改 session.ts · 2:14")     // 第 2 阶段换成真实动作 + 计时
                .foregroundStyle(IslandTheme.dim)
                .monospacedDigit()
                .lineLimit(1)
                .padding(.trailing, 11)
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
            // 已结束的不发光，免得"闲着"看起来像"有事"。
            .shadow(color: status == .ended ? .clear : color.opacity(0.85), radius: 3)
    }
}
