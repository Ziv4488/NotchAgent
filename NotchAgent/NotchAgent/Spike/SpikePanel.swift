//
//  SpikePanel.swift
//  探针 B —— 验证 .nonactivatingPanel 中的 SwiftTerm 能否正常接收按键。
//
//  第一轮失败的教训：macOS 只把键盘事件发给「激活的 app」。非激活面板能在自己
//  app 内成为 key window，但 app 不在前台时键仍然进前台那个 app。Spotlight /
//  Raycast 能打字是因为它们弹出时确实激活了自己。所以展开态必须 NSApp.activate()，
//  并且要显式把终端设为 first responder。收起时把焦点交还给原来的 app。
//
//  这是抛弃型代码，第 0.6 步会删除。
//

import AppKit
import SwiftTerm

final class SpikePanel: NSPanel {

    /// 模拟真实的岛：只在展开态为 true。
    var allowsKey = false {
        didSet {
            guard allowsKey != oldValue else { return }
            allowsKey ? takeFocus() : giveBackFocus()
        }
    }

    override var canBecomeKey: Bool { allowsKey }

    /// 第二轮的关键改动：原先写死 false。SwiftTerm 靠 interpretKeyEvents 走输入法
    /// 链路插入文本，而输入上下文需要窗口能成为 main 才会激活 —— 否则按键进得来
    /// 却一个字也插不进去，中文更是完全没有候选框。
    override var canBecomeMain: Bool { allowsKey }

    private let terminal = LocalProcessTerminalView(frame: .zero)
    private var previousApp: NSRunningApplication?

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
        installIMEWindowRaiser()
    }

    // MARK: - 输入法候选框遮挡

    /// 采样发现：输入法候选框是**本进程内**的窗口，层级固定 20。面板在 26，
    /// 所以候选框被压在下面。又因为菜单栏在 24，面板不可能同时高于菜单栏、
    /// 低于候选框 —— 唯一解法是反过来把候选框抬到面板之上。
    private func installIMEWindowRaiser() {
        imeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            DispatchQueue.main.async { self?.raiseInputMethodWindows() }
            return event
        }
    }

    private func raiseInputMethodWindows() {
        guard allowsKey else { return }
        let target = NSWindow.Level(rawValue: level.rawValue + 1)
        for window in NSApp.windows
        where window !== self && window.isVisible && window.level.rawValue == candidateWindowLevel {
            window.level = target
            SpikeLog.write("抬升候选框窗口 \(type(of: window)) \(window.frame) → 层级 \(target.rawValue)")
        }
    }

    private let candidateWindowLevel = 20
    private var imeMonitor: Any?

    /// 摆到屏幕顶部居中、贴着菜单栏下沿，大致模拟真实岛的位置。
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
        guard terminal.process.running == false else {
            SpikeLog.write("startShell 跳过：进程已在跑")
            return
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        SpikeLog.write("startShell: \(shell) -l")
        terminal.startProcess(executable: shell, args: ["-l"])
        // 启动是异步的，稍后复查一次是否真的起来了
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            SpikeLog.write("startShell 复查: running=\(self.terminal.process.running)")
        }
    }

    override func keyDown(with event: NSEvent) {
        SpikeLog.write("panel.keyDown keyCode=\(event.keyCode) chars=\(event.characters?.debugDescription ?? "nil")")
        super.keyDown(with: event)
    }

    // MARK: - 焦点

    private func takeFocus() {
        previousApp = NSWorkspace.shared.frontmostApplication
        SpikeLog.write("takeFocus 开始，展开前前台 app = \(previousApp?.localizedName ?? "?")")
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        makeMain()
        let ok = makeFirstResponder(terminal)
        SpikeLog.write("makeFirstResponder(terminal) = \(ok)")
        terminal.inputContext?.activate()
        SpikeLog.write("takeFocus 完成 ↓\n\(diagnostics)")
    }

    private func giveBackFocus() {
        orderFront(nil)          // 面板保持可见，只是不再拿焦点
        previousApp?.activate()  // 焦点还给展开前那个 app
        previousApp = nil
    }

    // MARK: - 诊断

    /// 供控制面板读取的实时状态，用来判断到底哪一环没成立。
    var diagnostics: String {
        let fr = firstResponder
        let t = terminal.getTerminal()
        return """
        NSApp.isActive        = \(NSApp.isActive)
        panel.isKeyWindow     = \(isKeyWindow)
        panel.isMainWindow    = \(isMainWindow)
        panel.canBecomeKey    = \(canBecomeKey)
        panel.canBecomeMain   = \(canBecomeMain)
        firstResponder        = \(fr.map { String(describing: type(of: $0)) } ?? "nil")
        终端是 firstResponder  = \(fr === terminal)
        终端 acceptsFirst…    = \(terminal.acceptsFirstResponder)
        终端 frame            = \(terminal.frame)
        终端 cols×rows        = \(t.cols)×\(t.rows)
        inputContext 存在      = \(terminal.inputContext != nil)
        inputContext 是当前的   = \(NSTextInputContext.current === terminal.inputContext)
        shell 在跑            = \(terminal.process.running)
        前台 app              = \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")
        """
    }
}
