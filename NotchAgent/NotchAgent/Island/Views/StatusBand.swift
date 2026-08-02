//
//  StatusBand.swift
//  NotchAgent
//
//  顶部状态带。左右分置，中间给物理刘海让路。
//

import SwiftUI

struct StatusBand: View {
    let model: IslandModel
    /// 岛主体宽度。
    let totalWidth: CGFloat
    /// 中间要空出来的宽度 —— 物理刘海占的地方，写不了字。
    let notchGap: CGFloat
    let height: CGFloat

    /// 左右两半各自的固定宽度。
    ///
    /// 原本这里用的是 `Spacer(minLength: notchGap)` —— 那只保证**下限**：
    /// 一侧内容比留给它的地方长，HStack 就直接把中缝压掉，文字于是从刘海底下开始。
    /// 改成两侧定宽、中间放一块死的占位，信息就绝无可能跑进刘海。
    /// 代价是内容超宽只能截断，但截断本来就是对的。
    private var sideWidth: CGFloat { Self.sideWidth(totalWidth: totalWidth, notchGap: notchGap) }

    static func sideWidth(totalWidth: CGFloat, notchGap: CGFloat) -> CGFloat {
        max(0, (totalWidth - notchGap) / 2)
    }

    var body: some View {
        HStack(spacing: 0) {
            leading.frame(width: sideWidth, alignment: .leading)
            Color.clear.frame(width: notchGap, height: 1)
            trailing.frame(width: sideWidth, alignment: .trailing)
        }
        .frame(width: totalWidth, height: height)
        .font(IslandTheme.bandFont)
    }

    // MARK: - 左侧：身份

    @ViewBuilder
    private var leading: some View {
        HStack(spacing: 5) {
            if let tab = model.selectedTab {
                StatusDot(status: tab.status)
                // 在跑的时候显示它在干什么（「读 session.ts」），闲着才显示项目名。
                // 收起态这一行是唯一的进度窗口，"refactor-auth" 不告诉你任何新信息。
                Text(StatusBand.line(for: tab, hookDegraded: model.hookChannelDegraded))
                    .foregroundStyle(IslandTheme.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if model.state == .expanded {
                // 一个会话都没有时，展开态落在新建流程上，状态带说清楚这件事。
                Text("新建任务").foregroundStyle(IslandTheme.dim)
            } else {
                // 连历史会话都没有，只写 app 名。
                // 这里原本还有个空心点，但 "NotchAgent" 实测 64pt、放不进去会折成两行；
                // 一个「什么都没在跑」的点本来也不携带信息，砍掉它把宽度让给名字。
                Text("NotchAgent").foregroundStyle(IslandTheme.faint)
            }
        }
        // 状态带只有一行高，任何折行都是错的 —— 宁可截断。
        .lineLimit(1)
        .padding(.leading, 10)
    }

    /// 收起态那一行字。
    ///
    /// 在跑的时候显示它在干什么（「读 session.ts」），闲着才显示项目名 ——
    /// 收起态这一行是唯一的进度窗口，"refactor-auth" 不告诉你任何新信息。
    ///
    /// **hook 通道断了要说出来。** 那时候 `activity` 永远是 nil，退回项目名的话
    /// 岛看起来就跟「没在跑」一模一样，用户只会以为功能坏了。
    /// 「运行中（无详情）」是 spec 6.4 定的降级文案：进度没了，但它确实在跑。
    static func line(for tab: IslandTab, hookDegraded: Bool) -> String {
        guard tab.status == .running else { return tab.title }
        if let activity = tab.activity { return activity }
        return hookDegraded ? "运行中（无详情）" : tab.title
    }

    // MARK: - 右侧：计时与窗口数

    @ViewBuilder
    private var trailing: some View {
        switch model.state {
        case .idle, .running:
            // 只留这两样：当前在跑多久、开着几个窗口。别的都往展开态里放。
            HStack(spacing: 7) {
                if let tab = model.timedTab {
                    ElapsedLabel(since: tab.startedAt)
                }
                if !model.tabs.isEmpty {
                    windowCount
                }
            }
            .padding(.trailing, 10)

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

    private var windowCount: some View {
        HStack(spacing: 3) {
            Image(systemName: "square.on.square")
                .font(.system(size: 8.5, weight: .semibold))
            Text("\(model.tabs.count)").monospacedDigit()
        }
        .foregroundStyle(IslandTheme.faint)
        .lineLimit(1)
    }
}

/// 从某一刻起走的计时。
struct ElapsedLabel: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(since)))
                .foregroundStyle(IslandTheme.dim)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 会话状态的小圆点。
///
/// 光靠颜色分不出「在跑」和「卡住等你」——「在跑」慢呼吸，「等你回话」快闪，
/// 余光扫一眼就知道该不该去管它。
struct StatusDot: View {
    let status: IslandTab.Status

    private var color: Color {
        switch status {
        case .running: IslandTheme.amber
        case .waiting: IslandTheme.blue
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
            .modifier(Pulse(status: status))
    }
}

private struct Pulse: ViewModifier {
    let status: IslandTab.Status
    @State private var lit = false

    private var period: Double? {
        switch status {
        case .running: 1.1
        case .waiting: 0.55
        case .done, .ended: nil
        }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let period {
            content
                .opacity(lit ? 1 : 0.3)
                .animation(.easeInOut(duration: period).repeatForever(autoreverses: true), value: lit)
                .onAppear { lit = true }
                .onDisappear { lit = false }
        } else {
            content
        }
    }
}
