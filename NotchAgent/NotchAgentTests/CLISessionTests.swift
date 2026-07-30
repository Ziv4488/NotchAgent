//
//  CLISessionTests.swift
//  NotchAgentTests
//
//  用脚本替身测，不依赖真的 claude —— 要测的是「进程怎么起、怎么退、
//  PTY 的尺寸有没有下去」，跟跑的是哪个程序无关。
//

import Foundation
import Testing
@testable import NotchAgent

@Suite("PTY 会话")
@MainActor
struct CLISessionTests {

    private func shell(_ script: String) -> CLISession.Launch {
        CLISession.Launch(executable: "/bin/sh", arguments: ["-c", script],
                          searchPath: "/usr/bin:/bin", settingsURL: nil)
    }

    private func session(_ script: String, directory: URL? = nil) -> CLISession {
        CLISession(title: "测试", workingDirectory: directory, launch: shell(script))
    }

    /// 等到状态不再是「活着」为止。轮询而不是靠回调，
    /// 是因为 SwiftTerm 的进程结束通知走的是它自己的队列。
    private func waitUntilDone(_ session: CLISession, timeout: TimeInterval = 10) async -> SessionStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !session.status.isAlive { return session.status }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return session.status
    }

    @Test("正常退出：退出码 0 落到状态里")
    func exitsZero() async throws {
        let session = session("exit 0")
        try session.start()
        #expect(await waitUntilDone(session) == .finished(0))
    }

    /// 退出码要原样留住 —— 第 4 阶段的错误态 UI 要靠它显示「退出码 3」并给重启按钮。
    @Test("非零退出：退出码原样保留，不被抹成通用失败")
    func exitsNonZero() async throws {
        let session = session("exit 3")
        try session.start()
        #expect(await waitUntilDone(session) == .finished(3))
    }

    @Test("起之前是 starting，起之后是 running")
    func statusProgression() throws {
        let session = session("sleep 5")
        #expect(session.status == .starting)
        try session.start()
        #expect(session.status == .running)
        session.terminate()
    }

    @Test("terminate 之后进程真的没了")
    func terminates() async throws {
        let session = session("sleep 30")
        try session.start()
        session.terminate()
        #expect(await waitUntilDone(session, timeout: 5).isAlive == false)
    }

    /// 岛被拖宽之后 PTY 的列数必须跟着变，否则 Claude Code 的 diff 和表格
    /// 会照着旧宽度排版，看起来像是渲染坏了。
    @Test("resize 之后 PTY 里的 stty 报出新的行列数")
    func resizeReachesThePTY() async throws {
        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "notch-stty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }

        let session = session("sleep 0.8; stty size > '\(output.path)'")
        try session.start()
        try await Task.sleep(for: .milliseconds(200))
        session.resize(cols: 132, rows: 40)
        _ = await waitUntilDone(session)

        let reported = (try String(contentsOf: output, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(reported == "40 132")
    }

    @Test("工作目录真的传给了子进程")
    func runsInWorkingDirectory() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "notch-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let marker = directory.appending(path: "here")
        let session = session("touch \"$(pwd)/here\"", directory: directory)
        try session.start()
        _ = await waitUntilDone(session)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    /// GUI app 继承的是 launchd 的窄 PATH。不把登录 shell 的 PATH 传下去，
    /// `claude` 自己起来了，它调 git / npm / rg 会全线失败。
    @Test("登录 shell 的 PATH 传到了子进程")
    func passesSearchPath() async throws {
        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "notch-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }

        let session = CLISession(
            title: "测试", workingDirectory: nil,
            launch: CLISession.Launch(
                executable: "/bin/sh",
                arguments: ["-c", "printf '%s' \"$PATH\" > '\(output.path)'"],
                searchPath: "/opt/custom/bin:/usr/bin:/bin", settingsURL: nil))
        try session.start()
        _ = await waitUntilDone(session)
        #expect(try String(contentsOf: output, encoding: .utf8) == "/opt/custom/bin:/usr/bin:/bin")
    }

    /// hook 事件靠这个环境变量绑回 tab（HookBridge 的第一行协议）。
    @Test("NOTCH_TAB 注入成了 tab 自己的 id")
    func injectsTabIdentity() async throws {
        let output = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "notch-tab-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }

        let id = UUID()
        let session = CLISession(
            id: id, title: "测试", workingDirectory: nil,
            launch: CLISession.Launch(
                executable: "/bin/sh",
                arguments: ["-c", "printf '%s' \"$NOTCH_TAB\" > '\(output.path)'"],
                searchPath: "/usr/bin:/bin", settingsURL: nil))
        try session.start()
        _ = await waitUntilDone(session)
        #expect(try String(contentsOf: output, encoding: .utf8) == id.uuidString)
    }

    // MARK: - 命令行拼装

    @Test("首个指令作为位置参数传进去，settings 也带上")
    func buildsArguments() {
        let launch = CLISession.Launch.claude(
            executable: "/x/claude", searchPath: "/usr/bin",
            settingsURL: URL(fileURLWithPath: "/s/island-hooks.json"),
            instruction: "跑测试", resume: false)
        #expect(launch.arguments == ["--settings", "/s/island-hooks.json", "跑测试"])
    }

    @Test("继续上次会话时带 --resume，不带指令")
    func buildsResume() {
        let launch = CLISession.Launch.claude(
            executable: "/x/claude", searchPath: "/usr/bin",
            settingsURL: URL(fileURLWithPath: "/s/island-hooks.json"),
            instruction: nil, resume: true)
        #expect(launch.arguments == ["--settings", "/s/island-hooks.json", "--resume"])
    }

    /// 空指令当成没有指令。传一个空字符串进去，`claude` 会把它当成一句空提问。
    @Test("空指令不会变成一个空的位置参数")
    func dropsEmptyInstruction() {
        let launch = CLISession.Launch.claude(
            executable: "/x/claude", searchPath: "/usr/bin",
            settingsURL: URL(fileURLWithPath: "/s/h.json"),
            instruction: "", resume: false)
        #expect(launch.arguments == ["--settings", "/s/h.json"])
    }
}
