//
//  CLISession.swift
//  NotchAgent
//
//  一个跑在伪终端里的 Claude Code 会话（spec 5.1）。
//

import AppKit
import Foundation
import OSLog
import SwiftTerm

/// 把 `claude` 起在伪终端里，交互与真终端完全一致。
///
/// **为什么是交互式而不是 `claude -p`**：斜杠命令、`Esc` 中断、权限确认、`/clear`、
/// ⇧Tab 切模式 —— 这些全是 TUI 行为，只有真的给它一个 PTY 才有。
/// 这就是「与终端体验一致」这条硬要求的实现方式，不是实现细节。
@MainActor
final class CLISession: NSObject, AgentSession, LocalProcessTerminalViewDelegate {
    let id: SessionID
    private(set) var title: String
    let workingDirectory: URL?
    private(set) var status: SessionStatus = .starting {
        didSet {
            guard status != oldValue else { return }
            callbacks.onStatusChanged?(id, status)
        }
    }

    /// Claude Code 自己的 session id，`SessionStart` hook 到达时才知道。
    private(set) var claudeSessionID: String?

    let terminalView: ObservingTerminalView
    let callbacks = SessionCallbacks()

    private let launch: Launch
    private let log = Logger(subsystem: "com.notchagent", category: "cli-session")

    /// 起一个进程需要的全部东西。抽成结构体是为了测试能塞一个脚本替身进来，
    /// 不必真的有 `claude` 才能测「非零退出怎么办」。
    struct Launch {
        var executable: String
        var arguments: [String]
        /// 登录 shell 的 PATH。不传的话 `claude` 起来了也找不到 `git` / `npm` / `rg`。
        var searchPath: String
        var settingsURL: URL?

        static func claude(executable: String, searchPath: String, settingsURL: URL,
                           instruction: String?, resume: Bool) -> Launch {
            var arguments = ["--settings", settingsURL.path]
            if resume { arguments.append("--resume") }
            // 首个指令作为位置参数传入：TUI 起来后自动带着它跑第一轮。
            if let instruction, !instruction.isEmpty { arguments.append(instruction) }
            return Launch(executable: executable, arguments: arguments,
                          searchPath: searchPath, settingsURL: settingsURL)
        }
    }

    init(id: SessionID = UUID(), title: String, workingDirectory: URL?, launch: Launch) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.launch = launch
        // 尺寸随后由 SwiftUI 那层布局决定；这里给个非零初值，避免 cols/rows 算成 0。
        self.terminalView = ObservingTerminalView(frame: CGRect(x: 0, y: 0, width: 560, height: 320))
        super.init()
        terminalView.processDelegate = self
        terminalView.configureNativeColors()
        // 键盘事件本来就在主线程上，这里只是把隔离说清楚。
        terminalView.onSend = { [weak self] bytes in
            MainActor.assumeIsolated {
                guard let self, TerminalKeystroke.isEscape(bytes) else { return }
                self.callbacks.onEscape?(self.id)
            }
        }
    }

    // MARK: - AgentSession

    func start() throws {
        log.info("起会话 \(self.title, privacy: .public) 于 \(self.workingDirectory?.path ?? "-", privacy: .public)")
        terminalView.startProcess(executable: launch.executable,
                                  args: launch.arguments,
                                  environment: environment(),
                                  currentDirectory: workingDirectory?.path)
        status = .running
    }

    func write(_ text: String) {
        terminalView.send(txt: text)
    }

    /// 一般不用手动调：SwiftTerm 在视图布局变化时会自己把新的 cols/rows 推给 PTY。
    /// 这个方法留给协议以及「岛被拖大了但视图还没重新布局」的场合。
    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        terminalView.getTerminal().resize(cols: cols, rows: rows)
        terminalView.sizeChanged(source: terminalView, newCols: cols, newRows: rows)
    }

    /// 关掉这个会话。
    ///
    /// **状态要自己置，SwiftTerm 不会回调。** 它的 `LocalProcess.terminate()`
    /// 发完 SIGTERM 就直接 `childStopped()`，`processTerminated` delegate 一次都不叫 ——
    /// 光靠 delegate 的话，被关掉的 tab 会永远停在「运行中」。
    func terminate() {
        guard status.isAlive else { return }
        terminalView.terminate()
        // 128 + SIGTERM，和用户在终端里 kill 一个进程后看到的 $? 一致。
        status = .finished(128 + SIGTERM)
    }

    /// 中断当前这一轮，等价于在终端里按 `Esc`。
    ///
    /// **不是 SIGINT。** Claude Code 的 TUI 把 `Esc` 定义成「停下这一轮但留着会话」，
    /// 而 `Ctrl-C` / SIGINT 在它那里是退出整个进程 —— 岛上的停止键要的是前者。
    ///
    /// 这一下同样会走 `onSend`，于是「岛上按停止」和「终端里按 Esc」
    /// 在上层是同一条路 —— 本来也该是同一件事。
    func interrupt() {
        terminalView.send(txt: "\u{1b}")
    }

    /// 当前可见屏的每一行文字。
    ///
    /// **必须从 SwiftTerm 渲染完的缓冲区里取，不能扒 PTY 的原始字节。**
    /// Claude Code 的 TUI 大量用光标定位来排版：一段「Do you want to create note.txt?」
    /// 在字节流里是「Do」+ 光标右移 + 「you」+ 光标右移…… 把转义序列剥掉之后
    /// 得到的是 `Doyouwanttocreatenote.txt?` —— 探针里就是这么发现的。
    /// 空格根本不在字节里，它是渲染的结果。
    /// 两处都不能省，都是从真实 dump 里发现的：
    ///
    /// - `skipNullCellsFollowingWide`：一个汉字占两格，第二格是空的。
    ///   不跳过的话「晚饭吃什么」取出来是「晚 饭 吃 什 么」，字字带空格。
    /// - 把剩下的 `\0` 换成空格：没被写过的格子在缓冲区里是 NUL 不是空格，
    ///   「Do you want to…」会变成「Do\0you\0want\0to…」，按词匹配全废。
    ///
    /// SwiftTerm 自己的 `getText` 两件事都做了，只是它不按行返回。
    func visibleLines() -> [String] {
        let terminal = terminalView.getTerminal()
        return (0..<terminal.rows).map { row in
            let line = terminal.getLine(row: row)?
                .translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? ""
            return line.replacingOccurrences(of: "\u{0}", with: " ")
        }
    }

    // MARK: - 环境

    private func environment() -> [String] {
        var variables = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        variables.append("PATH=\(launch.searchPath)")
        // hook 命令继承这个变量，用它把事件绑回到本 tab（HookBridge 里的第一行协议）。
        variables.append("NOTCH_TAB=\(id.uuidString)")
        // 探针里踩到的坑：从一个 Claude Code 会话里启动的进程会带着这个标记，
        // 子会话的 transcript 不会被保存 —— 而 transcript 是「继续上次会话」的依据。
        // app 正常启动时没有它，这里是防御性地确保不会被传下去。
        variables.removeAll { $0.hasPrefix("CLAUDE_CODE_CHILD_SESSION=") }
        return variables
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // 终端标题归终端，tab 上显示的是项目名 —— 让 `claude` 改掉它会让 tab 认不出来。
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// 注意参数名骗人：SwiftTerm 传过来的是 `waitpid` 的原始状态字，不是退出码。
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let waitStatus = exitCode else {
            status = .failed("进程异常中断")
            return
        }
        guard status.isAlive else { return }
        status = .fromWaitStatus(waitStatus)
    }

    // MARK: - hook 事件

    func bind(claudeSessionID: String) {
        self.claudeSessionID = claudeSessionID
    }
}
