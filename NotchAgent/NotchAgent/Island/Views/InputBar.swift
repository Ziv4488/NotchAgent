//
//  InputBar.swift
//  NotchAgent
//
//  展开态底部的输入框。第 2 阶段这里的按键直接喂给 PTY。
//

import SwiftUI

struct InputBar: View {
    /// 会话正在跑。此时发送键要变成停止键 —— 手边就该有中断的办法。
    var isRunning: Bool = false
    var onSubmit: (String) -> Void = { _ in }
    var onStop: () -> Void = {}

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            TextField(isRunning ? "正在执行…" : "追问或下达新指令…", text: $text)
                .textFieldStyle(.plain)
                .font(IslandTheme.inputFont)
                .foregroundStyle(IslandTheme.bright)
                // 展开就该能直接打字，不该还要再点一下（测试 2.1）。
                .focused($focused)
                .onAppear { claimFocus() }
                .onSubmit(send)

            actionButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // 圆角跟内容区那张卡同一个（`PanelCard.cardRadius`）：会话结束之后
        // 这一条就是岛最底下那一层，它的下角要和岛的下角同心。
        .background {
            RoundedRectangle(cornerRadius: PanelCard.cardRadius, style: .continuous)
                .fill(IslandTheme.inputFill)
                .overlay {
                    RoundedRectangle(cornerRadius: PanelCard.cardRadius, style: .continuous)
                        .strokeBorder(IslandTheme.inputStroke, lineWidth: 0.5)
                }
        }
        .padding(.horizontal, 7)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var actionButton: some View {
        Button(action: isRunning ? onStop : send) {
            Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: isRunning ? 8 : 9, weight: .bold))
                .foregroundStyle(isRunning ? Color.white : Color.white.opacity(0.8))
                .frame(width: 18, height: 18)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isRunning ? IslandTheme.stop : Color.white.opacity(0.16))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 第 2 阶段这里改成给 PTY 发 Esc / SIGINT，和终端里按 Esc 等效。
        .help(isRunning ? "停止" : "发送")
    }

    /// 抢两次焦点，不是一次。
    ///
    /// `takeFocus()` 里的 `NSApp.activate()` 是**异步**的：这个视图 onAppear 时窗口
    /// 很可能还没真的成为 key。而 app 一旦激活，AppKit 会把 first responder 恢复成
    /// 它记着的上一个，把这里刚设的焦点顶掉 —— 表现就是「展开了但没有光标，得再点一下」。
    /// 下一轮 runloop 再要一次，那时窗口已经稳定。
    private func claimFocus() {
        focused = true
        Task { @MainActor in focused = true }
    }

    private func send() {
        guard !text.isEmpty else { return }
        onSubmit(text)
        text = ""
    }
}
