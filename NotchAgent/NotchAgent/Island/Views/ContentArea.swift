//
//  ContentArea.swift
//  NotchAgent
//
//  展开态的内容区：CLI tab 放真实终端，app tab 整块不绘制、
//  把真实窗口贴在下面（第 3 阶段）。
//

import SwiftUI

struct ContentArea: View {
    let model: IslandModel
    let tab: IslandTab?

    var body: some View {
        Group {
            if let tab, tab.kind == .app {
                // app tab：内容区和输入框整体不绘制，真实窗口贴在 tab 条下方（spec 3.2）。
                Color.clear
            } else if let tab, let session = model.runtime?.session(tab.id) {
                terminal(session)
            } else if let tab, tab.isDetached {
                detached(tab)
            } else if let error = model.launchError {
                notice(error, symbol: "exclamationmark.triangle")
            } else {
                notice("这个会话没有活着的进程。", symbol: "moon.zzz")
            }
        }
        // 高度由外层 VStack 分配：状态带 / tab 条 / 输入框都是固定高，剩下的全归内容区。
        .frame(maxHeight: .infinity)
    }

    private func terminal(_ session: CLISession) -> some View {
        TerminalPane(session: session)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(IslandTheme.panelFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(IslandTheme.panelStroke, lineWidth: 0.5)
                    }
            }
            .padding(.horizontal, 7)
    }

    /// 进程已经退出的 tab：会话记录还在 `~/.claude`，可以 `--resume` 接回去。
    private func detached(_ tab: IslandTab) -> some View {
        panel {
            VStack(spacing: 10) {
                Text(tab.activity ?? "会话已结束。")
                    .font(IslandTheme.bodyFont)
                    .foregroundStyle(IslandTheme.dim)
                Button {
                    model.resumeTab(tab.id)
                } label: {
                    Text("继续上次会话")
                        .font(IslandTheme.tabFont)
                        .foregroundStyle(Color.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.14))
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func notice(_ text: String, symbol: String) -> some View {
        panel {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(IslandTheme.faint)
                Text(text)
                    .font(IslandTheme.bodyFont)
                    .foregroundStyle(IslandTheme.dim)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
        }
    }

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(IslandTheme.panelFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(IslandTheme.panelStroke, lineWidth: 0.5)
                    }
            }
            .padding(.horizontal, 7)
    }
}
