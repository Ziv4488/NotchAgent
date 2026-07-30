//
//  TerminalPane.swift
//  NotchAgent
//
//  把 CLISession 的终端视图放进 SwiftUI（spec 4.3 里 PTY → SwiftTerm → 内容区那一段）。
//

import AppKit
import SwiftUI
import SwiftTerm

/// 一个会话的终端。
///
/// **键盘直接归它。** 权限询问的 `1/2/3`、⇧Tab 切模式、`Esc` 中断、斜杠命令的补全菜单，
/// 全是 TUI 自己在处理的按键；焦点只要不在终端上，这些就全废了 ——
/// 而「交互和真终端一模一样」是这个项目的硬要求，不是可以打折的部分。
/// SwiftTerm 的 `TerminalView` 实现了 `NSTextInputClient`，中文输入法照常可用。
struct TerminalPane: NSViewRepresentable {
    let session: CLISession

    func makeNSView(context: Context) -> NSView {
        let host = FocusingContainer()
        let terminal = session.terminalView
        terminal.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: host.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.terminal = terminal
        style(terminal)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        guard let host = host as? FocusingContainer else { return }
        // 切 tab 时终端视图会被换掉，重新挂一次。
        if host.terminal !== session.terminalView {
            host.terminal?.removeFromSuperview()
            let terminal = session.terminalView
            terminal.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(terminal)
            NSLayoutConstraint.activate([
                terminal.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                terminal.topAnchor.constraint(equalTo: host.topAnchor),
                terminal.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            host.terminal = terminal
            style(terminal)
        }
        host.claimFocus()
    }

    /// 第 4 阶段的「终端配色与字体」会把这里换成可配置的；现在先钉死成岛的样子。
    private func style(_ terminal: LocalProcessTerminalView) {
        terminal.nativeBackgroundColor = .clear
        terminal.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        terminal.caretColor = NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        terminal.wantsLayer = true
        terminal.layer?.backgroundColor = .clear
    }
}

/// 只做一件事：视图一挂到窗口上就把终端设成 first responder。
///
/// 和 `InputBar` 里那次是同一个坑 —— `NSApp.activate()` 是异步的，
/// 视图刚建好时窗口还不是 key，这时候设 first responder 会在 app 真正激活后
/// 被 AppKit 恢复成它记着的上一个。所以要在下一轮 runloop 再抢一次。
private final class FocusingContainer: NSView {
    weak var terminal: LocalProcessTerminalView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claimFocus()
    }

    func claimFocus() {
        guard let window, let terminal, window.firstResponder !== terminal else { return }
        window.makeFirstResponder(terminal)
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, let terminal = self.terminal else { return }
            if window.firstResponder !== terminal {
                window.makeFirstResponder(terminal)
            }
        }
    }
}
