//
//  SessionReaper.swift
//  NotchAgent
//
//  把「岛起的、但已经不在岛底下」的 claude 收掉。
//

import Foundation
import OSLog

/// 按命令行特征找出并结束 claude 进程。
///
/// **为什么需要这个东西。** 岛起会话是 fork 一个子进程挂在 PTY 上，正常情况下
/// 岛一退、PTY 主端一关，子进程拿到 SIGHUP 就跟着走 —— 直接 `kill -9` 岛也一样，
/// 实测残留 0 个。但 Claude Code 2.1 自己带了守护进程（`claude daemon run` +
/// `--bg-pty-host`），会话有时候会被交出去，交出去之后它的父进程就成了那个
/// daemon（PID 1 底下），跟岛再没有父子关系。
///
/// 2026-08-01 在用户机器上抓到过两个这样的：岛已经退了一个半小时，两个带着
/// **岛自己那份** `--settings …/NotchAgent/island-hooks.json` 的会话还活着。
///
/// 退出确认框上写着「退出会终止所有正在运行的 Claude Code 会话」。用户的原话是
/// 「不然跟弹框显示的信息不一致」—— 那句话必须是真的，所以杀完子进程再按命令行
/// 特征扫一遍。
///
/// **认人只认岛自己的东西**：
/// - 关单个 tab 时认 `--session-id <那一个 UUID>`
/// - 退整个 app 时认 `--settings <岛自己那份 settings 的绝对路径>`
///
/// 两个特征都只有岛起的进程才带得上，不会误伤用户自己在终端里跑的 claude。
struct SessionReaper {

    /// 找出命令行里含有这段文字的、**本用户的**进程。默认走 `pgrep`。
    var find: (String) -> [pid_t] = SessionReaper.pgrep
    /// 发信号。默认走 `kill(2)`。
    var send: (pid_t, Int32) -> Void = { kill($0, $1) }
    /// SIGTERM 之后等多久再看还有没有活着的。
    var gracePeriod: TimeInterval = 0.4

    private static let log = Logger(subsystem: "com.notchagent", category: "reaper")

    /// 收掉所有命令行里带 `signature` 的 claude。返回真的发了信号的那些 pid。
    ///
    /// 先 SIGTERM，留一段时间让它自己收尾（Claude Code 会把 transcript 落盘）；
    /// 还赖着的才 SIGKILL。
    @discardableResult
    func reap(signature: String) -> [pid_t] {
        let victims = find(signature).filter { $0 != getpid() }
        guard !victims.isEmpty else { return [] }

        Self.log.info("岛外面还剩 \(victims.count) 个 claude，收掉：\(victims, privacy: .public)")
        for pid in victims { send(pid, SIGTERM) }

        // 退出路径上是同步等的：这里只有几百毫秒，而放它们活着的代价是
        // 弹框上那句话变成假的。
        Thread.sleep(forTimeInterval: gracePeriod)

        let stubborn = find(signature).filter { $0 != getpid() }
        for pid in stubborn { send(pid, SIGKILL) }
        return victims
    }

    /// 交给 `pgrep` 的那串参数。
    ///
    /// - `-f`：拿**整条命令行**去匹配 —— 我们的特征都在参数里，不在进程名里
    /// - `-U`：只看本用户的进程，别人的不该碰
    /// - `--`：**不能省**。我们的特征全都以 `--` 开头（`--settings`、`--session-id`），
    ///   不加分隔符的话 `pgrep` 会把它当成自己的选项，直接
    ///   `illegal option -- -` 退出码 2 —— 一个进程都扫不到，而且悄无声息。
    ///   实机上就是这么发现的：岛退了，四个该收的会话一个没少。
    static func pgrepArguments(pattern: String, uid: uid_t) -> [String] {
        ["-f", "-U", String(uid), "--", pattern]
    }

    /// `pgrep -f -U <uid> -- <pattern>`。
    static func pgrep(_ pattern: String) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = pgrepArguments(pattern: pattern, uid: getuid())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log.error("pgrep 起不来：\(error.localizedDescription, privacy: .public)")
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }
}
