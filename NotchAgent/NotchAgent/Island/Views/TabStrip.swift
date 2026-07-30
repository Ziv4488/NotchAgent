//
//  TabStrip.swift
//  NotchAgent
//
//  tab 条。notice 与 expanded 两态共用，末尾是新建。
//

import SwiftUI
import AppKit

struct TabStrip: View {
    let model: IslandModel
    var onNewTask: () -> Void = {}

    var body: some View {
        HStack(spacing: Layout.tabGap) {
            ForEach(model.tabs) { tab in
                TabChip(tab: tab, isSelected: tab.id == model.selectedTab?.id)
                    .onTapGesture { model.selectTab(tab.id) }
            }
            Button(action: onNewTask) {
                Text("＋")
                    .font(IslandTheme.tabFont)
                    .foregroundStyle(Color.white.opacity(0.3))
                    .padding(.horizontal, Layout.plusHPadding)
                    .padding(.vertical, Layout.chipVPadding)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Layout.stripHPadding)
        .frame(height: Layout.stripHeight)
    }
}

private struct TabChip: View {
    let tab: IslandTab
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 5) {
            icon
            Text(tab.title)
                .font(IslandTheme.tabFont)
                .foregroundStyle(isSelected ? IslandTheme.bright : Color.white.opacity(0.5))
                .lineLimit(1)
        }
        .padding(.horizontal, TabStrip.Layout.chipHPadding)
        .padding(.vertical, TabStrip.Layout.chipVPadding)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(IslandTheme.tabActiveFill)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.white.opacity(0.13)).frame(height: 0.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .contentShape(Rectangle())
    }

    /// 图标始终在，状态挂角标 —— 用状态点顶掉图标会让 tab 失去身份，
    /// 而 tab 条最要紧的就是「哪个是哪个」。
    private var icon: some View {
        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
            .fill(tab.status == .ended ? tab.accent.opacity(0.35) : tab.accent)
            .frame(width: TabStrip.Layout.iconSize, height: TabStrip.Layout.iconSize)
            .overlay {
                Image(systemName: tab.kind == .cli ? "terminal" : "app")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
            }
            .overlay(alignment: .bottomTrailing) { badge }
    }

    @ViewBuilder
    private var badge: some View {
        switch tab.status {
        case .done where tab.unread:
            // 完成且未读：绿色对勾（spec 3.1）。
            dot(IslandTheme.green) {
                Image(systemName: "checkmark")
                    .font(.system(size: 5, weight: .black))
                    .foregroundStyle(.black)
            }
        case .waiting:
            // 停下来等你回话。这个必须比「在跑」更抓眼 —— 不理它就一直卡着。
            dot(IslandTheme.blue) {
                Image(systemName: "questionmark")
                    .font(.system(size: 5, weight: .black))
                    .foregroundStyle(.white)
            }
        case .running:
            dot(IslandTheme.amber) { EmptyView() }
        default:
            EmptyView()
        }
    }

    private func dot<Content: View>(_ color: Color,
                                    @ViewBuilder content: () -> Content) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(content())
            .overlay(Circle().stroke(.black, lineWidth: 1.5))
            .offset(x: 3, y: 3)
    }
}

extension TabStrip {
    enum Layout {
        static let stripHeight: CGFloat = 34
        static let stripHPadding: CGFloat = 7
        static let tabGap: CGFloat = 3
        static let chipHPadding: CGFloat = 9
        static let chipVPadding: CGFloat = 4
        static let plusHPadding: CGFloat = 7
        static let iconSize: CGFloat = 14
    }

    /// tab 条渲染出来需要多宽 —— notice 态靠这个撑开（spec 3.1）。
    ///
    /// 用 AppKit 量文字宽度，比让 SwiftUI 先渲染再回读尺寸简单，
    /// 也避免了「量完再改宽度」这一帧的布局抖动。
    static func measuredWidth(for tabs: [IslandTab]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        var width = Layout.stripHPadding * 2

        for tab in tabs {
            let textWidth = (tab.title as NSString)
                .size(withAttributes: [.font: font]).width
            width += Layout.chipHPadding * 2 + Layout.iconSize + 5 + ceil(textWidth)
            width += Layout.tabGap
        }

        // 末尾的 ＋
        let plusWidth = ("＋" as NSString).size(withAttributes: [.font: font]).width
        width += Layout.plusHPadding * 2 + ceil(plusWidth)
        return width
    }
}
