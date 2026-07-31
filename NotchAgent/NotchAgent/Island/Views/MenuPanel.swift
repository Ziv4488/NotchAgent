//
//  MenuPanel.swift
//  NotchAgent
//
//  收起态时，把终端里那道选择题摆到岛下方（spec 3.1）。
//

import AppKit
import SwiftUI

/// 终端正在问你一个问题，选项直接挂在岛下面点。
///
/// **只在收起态出现。** 展开时终端本身就摆着那个选单，再叠一层浮层
/// 是同一份东西显示两遍，而且两处的光标位置还可能对不上。
///
/// 它是从岛上**长下来**的，不是另外一张卡片：和岛主体同宽、贴着岛的底边、
/// 只有最下面两个角是圆的。中间留一道缝会露出桌面，读起来就是两样东西。
struct MenuPanel: View {
    let menu: TerminalMenu
    /// 岛主体的宽度（不含两侧内凹圆弧占的边）。
    var width: CGFloat = Layout.width
    /// 最底下那两个角的圆角半径 —— 岛原本的底部圆角，现在由浮层来圆。
    ///
    /// **上面两个角是方的，也不往上盖。** 早先试过让背景往上钻进岛的底边去垫住
    /// 岛的圆角，结果把 tab 条的下沿一起盖掉了。现在改成岛那边把底部圆角收掉
    /// （见 `IslandModel.cornerRadii`），谁都不用压谁。
    var bottomRadius: CGFloat = 12
    var onChoose: (TerminalMenu.Option) -> Void

    /// 鼠标停在哪一项上。终端里的光标是另一回事（`isSelected`），两者可以不在一处。
    @State private var hovered: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            question
            ForEach(menu.options, id: \.number) { option in
                row(option)
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.bottom, 6)
        .background {
            UnevenRoundedRectangle(bottomLeadingRadius: bottomRadius,
                                   bottomTrailingRadius: bottomRadius,
                                   style: .continuous)
                .fill(.black)
        }
    }

    private var question: some View {
        Text(menu.question)
            .font(IslandTheme.tabFont)
            .foregroundStyle(IslandTheme.bright)
            .lineLimit(2)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ option: TerminalMenu.Option) -> some View {
        Button {
            onChoose(option)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                // 屏幕上印的就是这个数字，用户按键盘按的也是它 ——
                // 岛上重新编号会让两边对不上。
                Text("\(option.number)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected(option) ? IslandTheme.blue : IslandTheme.faint)
                    .frame(width: 14, alignment: .trailing)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(IslandTheme.tabFont)
                        .foregroundStyle(isSelected(option) ? IslandTheme.bright : IslandTheme.dim)
                        .lineLimit(1)
                    if let detail = option.detail {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(IslandTheme.faint)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill(for: option))
                    .padding(.horizontal, 6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 能点的东西要看得出能点。没有这一下，鼠标扫过去毫无反应，
        // 用户会以为浮层只是块显示。
        .onHover { inside in
            if inside { hovered = option.number }
            else if hovered == option.number { hovered = nil }
        }
    }

    /// 终端光标停着的那项最重（跟终端一致），鼠标底下的那项轻一档。
    private func fill(for option: TerminalMenu.Option) -> Color {
        if isSelected(option) { return IslandTheme.tabActiveFill }
        return hovered == option.number ? IslandTheme.hoverTint : .clear
    }

    /// 终端里光标停在哪一项，岛上就高亮哪一项 —— 两边必须是同一个状态，
    /// 否则用户一按回车会选到跟他看到的不一样的东西。
    private func isSelected(_ option: TerminalMenu.Option) -> Bool {
        menu.options.indices.contains(menu.selected)
            && menu.options[menu.selected].number == option.number
    }

    enum Layout {
        static let width: CGFloat = 320
    }
}

#Preview {
    VStack(spacing: 12) {
        MenuPanel(menu: TerminalMenu(
            question: "Do you want to create note.txt?",
            options: [
                .init(number: 1, title: "Yes", detail: nil),
                .init(number: 2, title: "Yes, allow all edits in spike-menu/ during this session", detail: nil),
                .init(number: 3, title: "No", detail: nil),
            ],
            selected: 0), onChoose: { _ in })

        MenuPanel(menu: TerminalMenu(
            question: "晚饭吃什么？",
            options: [
                .init(number: 1, title: "日式拉面", detail: "一碗热汤面，暖胃又省事，天冷或者累的时候最合适。"),
                .init(number: 2, title: "川菜小炒", detail: "重口味下饭，麻辣鲜香，适合想吃点刺激、开胃的时候。"),
                .init(number: 3, title: "Type something.", detail: nil),
            ],
            selected: 1), onChoose: { _ in })
    }
    .padding(30)
    .background(Color(white: 0.1))
}
