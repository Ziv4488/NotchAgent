//
//  InputBar.swift
//  NotchAgent
//
//  展开态底部的输入框。第 2 阶段这里的按键直接喂给 PTY。
//

import SwiftUI

struct InputBar: View {
    @State private var text = ""
    @FocusState private var focused: Bool
    var onSubmit: (String) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 7) {
            TextField("追问或下达新指令…", text: $text)
                .textFieldStyle(.plain)
                .font(IslandTheme.inputFont)
                .foregroundStyle(IslandTheme.bright)
                // 展开就该能直接打字，不该还要再点一下（测试 2.1）。
                .focused($focused)
                .onAppear { focused = true }
                .onSubmit {
                    guard !text.isEmpty else { return }
                    onSubmit(text)
                    text = ""
                }

            Image(systemName: "arrow.up")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.8))
                .frame(width: 18, height: 18)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.16))
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(IslandTheme.inputFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(IslandTheme.inputStroke, lineWidth: 0.5)
                }
        }
        .padding(.horizontal, 7)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}
