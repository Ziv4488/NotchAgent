//
//  SessionReaperTests.swift
//  NotchAgentTests
//
//  关掉岛 = 会话进程也没了。弹框上写的那句话得是真的。
//

import Foundation
import Testing
@testable import NotchAgent

/// 岛起的 claude 有时候不再是岛的子进程 —— Claude Code 2.1 会把会话交给
/// 它自己的守护进程。2026-08-01 在用户机器上抓到过：岛退了一个半小时，
/// 两个带着岛那份 `--settings` 的会话还活着，父进程是 PID 1 底下的
/// `claude daemon run`。
///
/// 退出确认框上写着「退出会终止所有正在运行的 Claude Code 会话」。
/// 用户的原话是「不然跟弹框显示的信息不一致」。
@Suite("收掉跑到岛外面的会话")
struct SessionReaperTests {

    /// 记下都给谁发了什么信号的假 reaper。
    private final class Log: @unchecked Sendable {
        var sent: [(pid_t, Int32)] = []
    }

    private func reaper(alive: @escaping (Int) -> [pid_t], log: Log) -> SessionReaper {
        var round = 0
        var reaper = SessionReaper()
        reaper.find = { _ in
            defer { round += 1 }
            return alive(round)
        }
        reaper.send = { pid, signal in log.sent.append((pid, signal)) }
        reaper.gracePeriod = 0
        return reaper
    }

    @Test("找到了就先 SIGTERM")
    func termsWhatItFinds() {
        let log = Log()
        // 第一轮找到两个，SIGTERM 之后就没了。
        let reaped = reaper(alive: { $0 == 0 ? [111, 222] : [] }, log: log)
            .reap(signature: "--session-id abc")

        #expect(reaped == [111, 222])
        #expect(log.sent.map(\.0) == [111, 222])
        #expect(log.sent.allSatisfy { $0.1 == SIGTERM })
    }

    /// SIGTERM 不走的才补 SIGKILL。Claude Code 收到 SIGTERM 会把 transcript
    /// 落盘，所以不能一上来就 -9 —— 那样这一轮的记录就没了。
    @Test("SIGTERM 之后还赖着的才 SIGKILL")
    func killsTheStubborn() {
        let log = Log()
        _ = reaper(alive: { _ in [333] }, log: log).reap(signature: "--settings x")

        #expect(log.sent.count == 2)
        #expect(log.sent[0] == (333, SIGTERM))
        #expect(log.sent[1] == (333, SIGKILL))
    }

    @Test("一个都没找到就不发信号")
    func doesNothingWhenNothingIsThere() {
        let log = Log()
        let reaped = reaper(alive: { _ in [] }, log: log).reap(signature: "--settings x")
        #expect(reaped.isEmpty)
        #expect(log.sent.isEmpty)
    }

    /// pgrep 的模式写得宽一点就可能把岛自己捞进来。**自杀是要防的。**
    @Test("绝不给自己发信号")
    func neverSignalsItself() {
        let log = Log()
        let me = getpid()
        let reaped = reaper(alive: { $0 == 0 ? [me, 444] : [] }, log: log)
            .reap(signature: "--settings x")

        #expect(reaped == [444])
        #expect(log.sent.map(\.0) == [444])
    }

    /// **`--` 不能省。** 我们的特征全都以 `--` 开头，不加分隔符的话 `pgrep`
    /// 会把它当成自己的选项：`illegal option -- -`，退出码 2，一个都扫不到，
    /// 而且悄无声息。第一版就是这么写的，实机上岛退了、四个该收的会话一个没少。
    @Test("pgrep 的参数里带 -- 分隔符")
    func pgrepSeparatesTheePattern() {
        let args = SessionReaper.pgrepArguments(pattern: "--settings /x/y.json", uid: 501)
        #expect(args == ["-f", "-U", "501", "--", "--settings /x/y.json"])
        // 分隔符必须在特征**前面**，否则等于没加。
        let separator = try? #require(args.firstIndex(of: "--"))
        #expect(separator != nil && separator! < args.count - 1)
    }

    /// 认人只认**岛自己那份** settings 的绝对路径 —— 用户在终端里自己跑的
    /// claude 不会带这个参数，误伤不了。
    @Test("退出时扫的是岛自己那份 settings")
    func signatureIsOurSettingsFile() {
        let url = URL(fileURLWithPath: "/Users/x/Library/Application Support/NotchAgent/island-hooks.json")
        #expect(SessionRuntime.launchSignature(settingsURL: url)
                == "--settings /Users/x/Library/Application Support/NotchAgent/island-hooks.json")
    }
}

/// 上面测的是「收的动作对不对」，这里测的是**收尾的路上真的会去收**。
/// 少了这两条，把 `reap` 从退出路径上删掉，上面那一套照样全绿。
@Suite("退出路上真的会去收")
@MainActor
struct SessionReaperCallSiteTests {

    @Test("退 app 时按 settings 路径扫一遍")
    func shutdownSweepsBySettingsPath() {
        let runtime = SessionRuntime()
        var patterns: [String] = []
        runtime.reaper.find = { patterns.append($0); return [] }

        runtime.shutdown()

        #expect(patterns == [SessionRuntime.launchSignature(settingsURL: runtime.bridge.settingsURL)])
    }

    /// 关单个 tab 时按 Claude 自己的 session id 扫 —— 那是个 UUID，
    /// 只可能是这一个会话，不会误伤别的 tab。
    @Test("关一个会话时按它的 session id 扫")
    func terminateSweepsBySessionID() throws {
        let session = CLISession(title: "测试", workingDirectory: nil,
                                 launch: .init(executable: "/bin/sh",
                                               arguments: ["-c", "sleep 30"],
                                               searchPath: "/usr/bin:/bin",
                                               settingsURL: nil))
        var patterns: [String] = []
        session.reaper.find = { patterns.append($0); return [] }
        session.bind(claudeSessionID: "af6e1646-9d04-46c4-ac11-f8deb0fa717c")
        try session.start()

        session.terminate()

        #expect(patterns == ["--session-id af6e1646-9d04-46c4-ac11-f8deb0fa717c"])
    }

    /// 还没收到 `SessionStart` hook 就被关掉的会话没有 session id，
    /// 这时候别拿一个空串去 pgrep —— 那会匹配到**所有**进程。
    @Test("没有 session id 就不扫")
    func doesNotSweepWithoutASessionID() throws {
        let session = CLISession(title: "测试", workingDirectory: nil,
                                 launch: .init(executable: "/bin/sh",
                                               arguments: ["-c", "sleep 30"],
                                               searchPath: "/usr/bin:/bin",
                                               settingsURL: nil))
        var called = false
        session.reaper.find = { _ in called = true; return [] }
        try session.start()

        session.terminate()

        #expect(!called)
    }
}
