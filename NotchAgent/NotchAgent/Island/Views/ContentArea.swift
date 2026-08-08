//
//  ContentArea.swift
//  NotchAgent
//
//  展开态的内容区：放真实终端。
//

import SwiftUI

struct ContentArea: View {
    let model: IslandModel
    let tab: IslandTab?
    /// 这块卡片下面留多宽的黑边。会话活着时它就是岛最底下那一层，要留；
    /// 下面还摞着输入框时由输入框自己留。见 `PanelCard.bottomInset`。
    var bottomInset: CGFloat = 0

    var body: some View {
        Group {
            switch Self.kind(tab: tab, session: session, launchError: model.launchError) {
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
        if let session, session.status.isAlive { return .terminal(session) }
        if tab.isDetached { return .detached(tab) }
        return launchError.map(Kind.launchError) ?? .noProcess
    }

    private func terminal(_ session: CLISession) -> some View {
        TerminalPane(session: session)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background { PanelCard() }
            .padding(.horizontal, PanelCard.inset)
            .padding(.bottom, bottomInset)
    }

    /// 进程已经退出的 tab：会话记录还在 `~/.claude`，可以 `--resume` 接回去。
    ///
    /// **正常结束和异常退出长得不一样。** 正常是一句平静的交代；异常要给一个
    /// 琥珀色的警告标 + 退出码（`tab.activity` 里已经写好了，见
    /// `IslandModel.endNote`），否则用户只知道「没了」，不知道为什么没了。
    /// 两种情况下的按钮是同一个 —— 会话记录都还在 `~/.claude`，都接得回去。
    /// 这两块卡片的墨色**跟着主题走，不写死白色**。
    ///
    /// 它们画在内容区那张卡片上，而卡片的底 2026-08-05 起是主题色 —— 选了浅色
    /// 主题（One Light 的底是 `#FAFAFA`）之后，原来那套白色的各档透明度
    /// 会淡到完全看不见。琥珀色那个警告标不用翻：深浅底上都读得出。
    private func detached(_ tab: IslandTab) -> some View {
        let theme = ThemeStore.shared.theme
        return panel {
            VStack(spacing: 10) {
                if tab.endedAbnormally {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(IslandTheme.amber)
                }
                Text(tab.activity ?? "会话已结束。")
                    .font(IslandTheme.bodyFont)
                    .foregroundStyle(tab.endedAbnormally ? theme.onSurfaceBright : theme.onSurfaceDim)
                    .multilineTextAlignment(.center)
                Button {
                    model.resumeTab(tab.id)
                } label: {
                    Text(tab.endedAbnormally ? "重新启动" : "继续上次会话")
                        .font(IslandTheme.tabFont)
                        .foregroundStyle(theme.controlLabel)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(theme.controlFill)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func notice(_ text: String, symbol: String) -> some View {
        let theme = ThemeStore.shared.theme
        return panel {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(theme.onSurfaceFaint)
                Text(text)
                    .font(IslandTheme.bodyFont)
                    .foregroundStyle(theme.onSurfaceDim)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
        }
    }

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { PanelCard() }
            .padding(.horizontal, PanelCard.inset)
            .padding(.bottom, bottomInset)
    }
}
