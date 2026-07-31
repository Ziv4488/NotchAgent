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
            switch Self.kind(tab: tab, session: session, launchError: model.launchError) {
            case .attachedApp:
                // app tab：内容区和输入框整体不绘制，真实窗口贴在 tab 条下方（spec 3.2）。
                Color.clear
            case .terminal(let session):
                terminal(session)
            case .detached(let tab):
                detached(tab)
            case .launchError(let message):
                notice(message, symbol: "exclamationmark.triangle")
            case .noProcess:
                notice("这个会话没有活着的进程。", symbol: "moon.zzz")
            }
        }
        // 高度由外层 VStack 分配：状态带 / tab 条 / 输入框都是固定高，剩下的全归内容区。
        .frame(maxHeight: .infinity)
    }

    private var session: CLISession? {
        guard let tab else { return nil }
        return model.runtime?.session(tab.id)
    }

    /// 这个 tab 的内容区该画什么。
    enum Kind {
        case attachedApp
        case terminal(CLISession)
        case detached(IslandTab)
        case launchError(String)
        case noProcess
    }

    /// **进程死了就别画它的终端。**
    ///
    /// 会话对象死后还留在 store 里（没人 close 它），而 Claude Code 退出时会
    /// 还原备用屏 —— 画出来是一整块黑，只有左上角一个光标，看着像 app 卡住了。
    /// 用户报过：旧 tab 走 `--resume`，在「选哪个 session」那一屏按 Esc，
    /// claude 当场退出，岛上就剩这么一块黑。
    ///
    /// 光看「有没有 session 对象」不够，得看它**还活着没有**。
    /// 死了就走下面那块「继续上次会话」—— 会话记录还在 `~/.claude`，接得回去。
    static func kind(tab: IslandTab?, session: CLISession?, launchError: String?) -> Kind {
        guard let tab else {
            return launchError.map(Kind.launchError) ?? .noProcess
        }
        if tab.kind == .app { return .attachedApp }
        if let session, session.status.isAlive { return .terminal(session) }
        if tab.isDetached { return .detached(tab) }
        return launchError.map(Kind.launchError) ?? .noProcess
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
