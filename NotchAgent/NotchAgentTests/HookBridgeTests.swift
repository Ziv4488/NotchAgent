//
//  HookBridgeTests.swift
//  NotchAgentTests
//

import Foundation
import Testing
@testable import NotchAgent

@Suite("hook 通道")
struct HookBridgeTests {

    // MARK: - 分帧

    @Test("第一行是 tab id 时把它拆出来，JSON 从第二行起")
    func splitsIdentityLine() {
        let id = UUID()
        let data = Data("\(id.uuidString)\n{\"a\":1}".utf8)
        let (tab, payload) = HookBridge.split(data)
        #expect(tab == id)
        #expect(String(decoding: payload, as: UTF8.self) == "{\"a\":1}")
    }

    /// 转发方式将来可能变，或者有人手动 `nc` 一条 payload 进来调试。
    /// 第一行不像 UUID 就当整包都是 JSON，通道不该因此哑掉。
    @Test("没有身份行时整包都当 JSON")
    func toleratesMissingIdentity() {
        let data = Data("{\"hook_event_name\":\"Stop\",\"session_id\":\"x\"}".utf8)
        let (tab, payload) = HookBridge.split(data)
        #expect(tab == nil)
        #expect(HookEvent.decode(payload)?.kind == .stop)
    }

    @Test("身份行是空的（NOTCH_TAB 没设上）时不认，但 JSON 照样解得开")
    func toleratesEmptyIdentity() {
        let data = Data("\n{\"hook_event_name\":\"Stop\",\"session_id\":\"x\"}".utf8)
        let (tab, payload) = HookBridge.split(data)
        #expect(tab == nil)
        #expect(HookEvent.decode(payload)?.kind == .stop)
    }

    // MARK: - 生成的 --settings

    /// 探针已验证 `--settings` 与用户设置是**合并**语义，且它定义的键**优先**。
    /// 所以这份文件里多写一个键就会顶掉用户自己的设置 —— 只能有 hooks。
    @Test("生成的设置里只有 hooks，绝不碰用户的其他配置")
    @MainActor
    func settingsContainOnlyHooks() throws {
        let bridge = HookBridge(socketURL: URL(fileURLWithPath: "/tmp/notch-test/hooks.sock"))
        try FileManager.default.createDirectory(at: bridge.settingsURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bridge.writeSettings()
        defer { try? FileManager.default.removeItem(at: bridge.settingsURL) }

        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: bridge.settingsURL)) as? [String: Any]
        #expect(object?.keys.sorted() == ["hooks"])
    }

    @Test("五个 hook 全都注册了 —— 少一个就有一种岛的状态永远不会亮")
    func registersEveryHook() {
        let hooks = HookBridge.hooks(socketPath: "/tmp/x.sock")
        #expect(hooks.keys.sorted() == ["Notification", "PostToolUse", "PreToolUse", "SessionStart", "Stop"])
    }

    /// hook 命令非零退出会被 Claude Code 当成错误报给用户。
    /// 岛没开着的时候每次工具调用都弹一次红字，是不能接受的。
    @Test("转发命令永远以成功退出，绝不把错误捅到用户的终端里")
    func neverFails() throws {
        let hooks = HookBridge.hooks(socketPath: "/tmp/x.sock")
        let commands = try commandStrings(in: hooks)
        #expect(commands.count == 5)
        for command in commands {
            #expect(command.hasSuffix("|| true"))
            #expect(command.contains("NOTCH_TAB"))
            #expect(command.contains("/usr/bin/nc -U -w 1"))
        }
    }

    @Test("socket 路径带空格也不会把命令拆断")
    func quotesSocketPath() throws {
        let hooks = HookBridge.hooks(socketPath: "/Users/a b/Application Support/x.sock")
        for command in try commandStrings(in: hooks) {
            #expect(command.contains("'/Users/a b/Application Support/x.sock'"))
        }
    }

    private func commandStrings(in hooks: [String: Any]) throws -> [String] {
        hooks.values.compactMap { value in
            guard let entries = value as? [[String: Any]],
                  let inner = entries.first?["hooks"] as? [[String: Any]] else { return nil }
            return inner.first?["command"] as? String
        }
    }

    // MARK: - 端到端：真的开一个 socket，用真的 nc 打进去

    /// 不模拟 —— 这条通道的全部风险都在「`nc` 到底怎么表现」上，
    /// 换成假的转发端就等于把要测的东西测掉了。
    @Test("nc 发一条真实 payload 进来，能解出事件和 tab id", .timeLimit(.minutes(1)))
    @MainActor
    func endToEndThroughNetcat() async throws {
        // 用 /tmp 而不是 NSTemporaryDirectory()：后者是 /var/folders/… 那种长路径，
        // 加上 socket 文件名会超过 sockaddr_un 的 104 字节上限。
        let directory = URL(fileURLWithPath: "/tmp/nh-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let bridge = HookBridge(socketURL: directory.appending(path: "hooks.sock"))
        let tab = UUID()
        let payload = try HookFixtures.data("stop")

        let received: (HookEvent, UUID?) = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            bridge.onEvent = { event, declaredTab in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: (event, declaredTab))
            }
            do {
                try bridge.start()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            send(payload: payload, tab: tab, socket: bridge.settingsURL
                .deletingLastPathComponent().appending(path: "hooks.sock").path)
        }
        bridge.stop()

        #expect(received.0.kind == .stop)
        #expect(received.1 == tab)
    }

    /// 「绝不阻塞 Claude Code」是硬要求：岛没开着的时候，
    /// 每一次工具调用都要走这条命令，它必须立刻失败返回。
    @Test("岛没跑的时候转发命令立刻退出，不会把 Claude Code 卡住")
    func failsFastWhenNobodyListens() throws {
        let missing = "/tmp/notch-nonexistent-\(UUID().uuidString).sock"
        let start = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo '{}' | /usr/bin/nc -U -w 1 '\(missing)' >/dev/null 2>&1 || true"]
        try process.run()
        process.waitUntilExit()
        let elapsed = Date().timeIntervalSince(start)

        #expect(process.terminationStatus == 0)
        #expect(elapsed < 1.0, "转发耗时 \(elapsed)s，太久了")
    }

    private func send(payload: Data, tab: UUID, socket: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "{ echo \"$NOTCH_TAB\"; cat; } | /usr/bin/nc -U -w 1 '\(socket)'"]
        process.environment = ["NOTCH_TAB": tab.uuidString]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        input.fileHandleForWriting.write(payload)
        try? input.fileHandleForWriting.close()
    }
}
