//
//  SpikePanel.swift
//  探针 B —— 验证 .nonactivatingPanel 中的 SwiftTerm 能否正常接收按键。
//
//  这是抛弃型代码，第 0.6 步会删除。
//

import AppKit
import SwiftTerm

/// 一个层级高于菜单栏的非激活面板，内容是跑着 shell 的终端。
/// `canBecomeKey` 由 `allowsKey` 动态控制，用来验证「平时不抢焦点、展开时能打字」是否成立。
final class SpikePanel: NSPanel {

    /// 动态控制能否成为 key window。模拟真实的岛：只在展开态为 true。
    var allowsKey = false {
        didSet {
            guard allowsKey != oldValue else { return }
            if allowsKey {
                makeKeyAndOrderFront(nil)
            } else {
                // 交还焦点：把 key 状态让出去，由系统交给下一个候选窗口
                resignKey()
                orderFront(nil)
            }
        }
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    private let terminal = LocalProcessTerminalView(frame: .zero)

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 340),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        title = "探针 B · 非激活面板中的终端"
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        terminal.autoresizingMask = [.width, .height]
        contentView = terminal

        positionUnderNotch()
    }

    /// 摆到屏幕顶部居中，贴着菜单栏下沿 —— 大致模拟真实岛的位置。
    private func positionUnderNotch() {
        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        let size = frame.size
        setFrameOrigin(NSPoint(
            x: f.midX - size.width / 2,
            y: f.maxY - screen.safeAreaInsets.top - size.height
        ))
    }

    func startShell() {
        guard terminal.process.running == false else { return }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        terminal.startProcess(executable: shell, args: ["-l"])
    }
}
