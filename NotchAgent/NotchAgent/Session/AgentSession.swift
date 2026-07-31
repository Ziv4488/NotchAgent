//
//  AgentSession.swift
//  NotchAgent
//
//  会话抽象（spec 4.2）。这层是「将来换成守护进程模式」的接缝：
//  v1 的 CLISession 直接持有子进程，将来的 DaemonSession 走 IPC，IslandShell 不用改。
//

import Foundation

typealias SessionID = UUID

enum SessionStatus: Equatable {
    /// 进程已 spawn，还没收到第一个事件。
    case starting
    /// 正在干活。
    case running
    /// 停下来等你回话：权限询问、澄清问题。
    case waiting
    /// 这一轮跑完了，但会话还活着，可以继续追问。
    ///
    /// spec 4.2 原本只列了 starting/running/waiting/finished/failed。
    /// 实测下来必须有这一档：`Stop` hook 表示「这一轮结束」，进程仍在跑；
    /// 没有它就只能在「还在干活」和「进程已退出」之间二选一，两个都是错的。
    case idle
    /// 进程退出，带退出码。
    case finished(Int32)
    /// 起不来或中途出错。
    case failed(String)

    var isAlive: Bool {
        switch self {
        case .starting, .running, .waiting, .idle: true
        case .finished, .failed: false
        }
    }

    /// 从 `waitpid` 的原始 wait status 解出退出码。
    ///
    /// **SwiftTerm 交给 delegate 的不是退出码，是 `waitpid` 的原始状态字**
    /// （`LocalProcess.processTerminated` 里 `waitpid(pid, &n, WNOHANG)` 之后直接把 `n` 发出来）。
    /// `exit 3` 到手里是 768（0x0300），不解码的话错误态 UI 会显示「退出码 768」。
    ///
    /// 被信号杀掉的按 shell 惯例记成 `128 + 信号`，和用户在终端里看到的 `$?` 一致。
    static func fromWaitStatus(_ status: Int32) -> SessionStatus {
        let signal = status & 0x7F
        if signal == 0 {
            return .finished((status >> 8) & 0xFF)
        }
        return .finished(128 + signal)
    }
}

@MainActor
protocol AgentSession: AnyObject, Identifiable {
    var id: SessionID { get }
    var title: String { get }
    var workingDirectory: URL? { get }
    var status: SessionStatus { get }

    func start() throws
    /// CLI：写进 PTY；App：无操作。
    func write(_ text: String)
    /// CLI：改 PTY 的窗口尺寸；App：无操作。
    func resize(cols: Int, rows: Int)
    func terminate()
}

/// 会话状态变化时告诉外面。用闭包而不是 delegate 协议 ——
/// 订阅方只有 `IslandModel` 一个，为它定义一个协议是多余的。
@MainActor
final class SessionCallbacks {
    var onStatusChanged: ((SessionID, SessionStatus) -> Void)?
    var onTitleChanged: ((SessionID, String) -> Void)?
    /// 用户在终端里按了 Esc —— 这一轮到此为止（见 `TerminalKeystroke`）。
    /// hook 通道在这条路上什么都不发，只有这一个信号。
    var onEscape: ((SessionID) -> Void)?
}
