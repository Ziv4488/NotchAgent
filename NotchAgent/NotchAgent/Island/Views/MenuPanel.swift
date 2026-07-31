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
    /// 岛底部的圆角半径。背景要往上多铺这么高去垫住那两个圆角 ——
    /// 不垫的话接缝处会漏出两个小三角。
    var joinRadius: CGFloat = 12
    var onChoose: (TerminalMenu.Option) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            question
            ForEach(menu.options, id: \.number) { option in
                row(option)
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.vertical, 6)
        .background {
            UnevenRoundedRectangle(bottomLeadingRadius: joinRadius,
                                   bottomTrailingRadius: joinRadius,
                                   style: .continuous)
                .fill(.black)
                // 往上钻进岛的底边里。两块都是纯黑，接出来是一整片。
                .padding(.top, -joinRadius)
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
                    .fill(isSelected(option) ? IslandTheme.tabActiveFill : Color.clear)
                    .padding(.horizontal, 6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
