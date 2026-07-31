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

    /// 正在改名的那个 tab。同一时刻只可能有一个。
    @State private var editingTabID: UUID?

    var body: some View {
        HStack(spacing: Layout.tabGap) {
            ForEach(model.tabs) { tab in
                TabChip(tab: tab,
                        isSelected: tab.id == model.selectedTab?.id,
                        isEditing: editingTabID == tab.id,
                        onCommit: { newTitle in
                            model.renameTab(tab.id, to: newTitle)
                            editingTabID = nil
                        },
                        onCancel: { editingTabID = nil })
                    // 双击的手势要挂在单击前面，否则单击先吃掉事件、双击永远不触发。
                    .onTapGesture(count: 2) {
                        // 收起态的 tab 条宽度是按标题量出来的（measuredWidth），
                        // 在那儿改名会让整块岛跟着抽。只在展开态允许。
                        guard model.state == .expanded else { return }
                        model.selectTab(tab.id)
                        editingTabID = tab.id
                    }
                    .onTapGesture {
                        editingTabID = nil
                        model.selectTab(tab.id)
                    }
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
    var isEditing = false
    var onCommit: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 5) {
            icon
            if isEditing {
                nameField
            } else {
                Text(tab.title)
                    .font(IslandTheme.tabFont)
                    .foregroundStyle(isSelected ? IslandTheme.bright : Color.white.opacity(0.5))
                    .lineLimit(1)
            }
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
        .onChange(of: isEditing, initial: true) { _, editing in
            guard editing else { return }
            draft = tab.title
            fieldFocused = true
        }
    }

    /// 原地改名。回车确认，Esc 放弃。
    ///
    /// 宽度自己量：TextField 在 HStack 里默认会把剩下的地方全占了，
    /// tab 条会被一个输入框撑满。按草稿实时量宽度，输入时芯片跟着长。
    private var nameField: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(IslandTheme.tabFont)
            .foregroundStyle(IslandTheme.bright)
            .focused($fieldFocused)
            .frame(width: TabStrip.fieldWidth(for: draft))
            .onSubmit { onCommit(draft) }
            // Esc 现在一路放行给终端（见 IslandWindowController.action），
            // 但改名时 first responder 是这个输入框，轮不到终端 —— 正好当「放弃」。
            .onExitCommand(perform: onCancel)
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
        static let minFieldWidth: CGFloat = 44
    }

    /// 改名输入框该多宽：按当前草稿量，另留一点余量给光标。
    ///
    /// 下限不是为了好看 —— 名字删空时输入框会缩成零宽，光标消失、
    /// 谁都不知道自己还在编辑状态，只能瞎按。
    static func fieldWidth(for draft: String) -> CGFloat {
        let measured = (draft as NSString).size(withAttributes: [.font: titleFont]).width
        return max(Layout.minFieldWidth, ceil(measured) + 6)
    }

    /// tab 标题用的字体。量宽度和渲染必须是同一个，否则量出来的宽度不作数。
    ///
    /// **别把这个变量叫 `font`。** `TabStrip` 是个 `View`，`View` 带一个
    /// `font(_:)` 修饰器；在静态方法里写 `[.font: font]`，`font` 会解析成
    /// 那个**没被调用的方法本身**。字典值类型是 `Any`，编译器一声不吭地收下，
    /// 到运行时 AppKit 拿着一个 `__SwiftValue` 去问它 `pointSize` ——
    /// app 在第一帧布局就 crash。这个坑踩过一次。
    static let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// tab 条渲染出来需要多宽 —— notice 态靠这个撑开（spec 3.1）。
    ///
    /// 用 AppKit 量文字宽度，比让 SwiftUI 先渲染再回读尺寸简单，
    /// 也避免了「量完再改宽度」这一帧的布局抖动。
    static func measuredWidth(for tabs: [IslandTab]) -> CGFloat {
        var width = Layout.stripHPadding * 2

        for tab in tabs {
            let textWidth = (tab.title as NSString)
                .size(withAttributes: [.font: titleFont]).width
            width += Layout.chipHPadding * 2 + Layout.iconSize + 5 + ceil(textWidth)
            width += Layout.tabGap
        }

        // 末尾的 ＋
        let plusWidth = ("＋" as NSString).size(withAttributes: [.font: titleFont]).width
        width += Layout.plusHPadding * 2 + ceil(plusWidth)
        return width
    }
}
