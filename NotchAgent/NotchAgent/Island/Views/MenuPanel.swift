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
    /// 终端在等一段自由输入时，这一段打进 PTY。
    var onSubmit: (String) -> Void = { _ in }
    /// 输入框被点了 —— 窗口层据此把键盘拿过来。
    var onFocusRequest: () -> Void = {}
    /// 输入态下按 Esc：原样发给终端（那儿印着「Esc to cancel」）。
    var onCancel: () -> Void = {}
    /// 从输入框退回那一排选项。
    var onBack: () -> Void = {}

    /// 鼠标停在哪一项上。
    @State private var hovered: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if menu.wantsTextEntry {
                // 终端已经不在让你选，而是在等你打字。选项还画在屏幕上，
                // 但它们不再是按钮 —— 这里一个都不摆，只摆输入框。
                TextEntryRow(prompt: menu.question,
                             onSubmit: onSubmit,
                             onFocusRequest: onFocusRequest,
                             onCancel: onCancel,
                             onBack: onBack)
            } else {
                question
                ForEach(menu.options, id: \.number) { option in
                    row(option)
                }
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
                    .foregroundStyle(IslandTheme.faint)
                    .frame(width: 14, alignment: .trailing)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(IslandTheme.tabFont)
                        .foregroundStyle(IslandTheme.dim)
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

    /// **只有鼠标底下那项亮。**
    ///
    /// 这里原本还跟着终端光标高亮一项（默认就是第 1 项）。拆掉了：浮层上的
    /// 选项是**按钮**，一进来就有一项带着底色，读起来是「已经选好了」，
    /// 而其实什么都还没发生。终端里那个 `❯` 是「回车会选中它」的意思，
    /// 岛上没有回车这条路（点哪项就打哪个数字），照搬过来只剩误导。
    private func fill(for option: TerminalMenu.Option) -> Color {
        hovered == option.number ? IslandTheme.hoverTint : .clear
    }

    enum Layout {
        static let width: CGFloat = 320
    }
}

/// 终端在等一段自由输入时，岛下面摆的那一行。
///
/// **不自动抢焦点。** 这个框可能在用户正在别的窗口里打字的时候冒出来，
/// 一出现就把键盘拽过去等于把他那句话打断在一半。所以：框先摆着，
/// 他点一下（`NotchWindow.activateForClick` 那时才激活 app）才归岛。
private struct TextEntryRow: View {
    let prompt: String
    var onSubmit: (String) -> Void
    var onFocusRequest: () -> Void
    var onCancel: () -> Void
    var onBack: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                backButton
                if !prompt.isEmpty {
                    Text(prompt)
                        .font(IslandTheme.tabFont)
                        .foregroundStyle(IslandTheme.bright)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 7) {
                TextField("打一句回给它…", text: $text)
                    .textFieldStyle(.plain)
                    .font(IslandTheme.inputFont)
                    .foregroundStyle(IslandTheme.bright)
                    .focused($focused)
                    .onSubmit(send)
                    // 屏幕上印着「Esc to cancel」，这里按 Esc 就得是那个意思。
                    .onExitCommand(perform: onCancel)

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .frame(width: 18, height: 18)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.16))
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(IslandTheme.inputFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(focused ? IslandTheme.blue.opacity(0.6) : IslandTheme.inputStroke,
                                          lineWidth: 0.5)
                    }
            }
            // 点框周围的留白也算点这个框 —— 那一圈看起来就是框的一部分。
            .contentShape(Rectangle())
            .onTapGesture { claimFocus() }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    /// 退回那一排选项。
    ///
    /// 点错了「Type something.」是常事，而这时候浮层上**一个选项都没有**了
    /// （它们已经不是按钮，画出来点一下就是往框里打数字）。没有这一下，
    /// 唯一的退路是 Esc —— 那会把整道题一起取消掉，不是他要的。
    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: 18, height: 16)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("回到选项")
    }

    /// 先让窗口够格拿键盘，再设 first responder。
    ///
    /// 顺序不能反，也不能只设一次：`NSApp.activate()` 是异步的，app 真正激活时
    /// AppKit 会把 first responder 恢复成它记着的上一个，把这里刚设的顶掉 ——
    /// 和 `NewTaskForm.focusInstruction()` 是同一个坑。
    private func claimFocus() {
        onFocusRequest()
        focused = true
        Task { @MainActor in focused = true }
    }

    private func send() {
        guard !text.isEmpty else { return }
        onSubmit(text)
        text = ""
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
