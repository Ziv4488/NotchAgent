//
//  HookEventTests.swift
//  NotchAgentTests
//
//  样本全部来自真机抓包（scripts/spike-hooks.sh 与 spike-notification.py），
//  不是照文档手写的 —— 文档和 Claude Code 2.1.220 实际发的 payload 有出入。
//

import Foundation
import Testing
@testable import NotchAgent

@Suite("hook payload 解码")
struct HookEventTests {

    @Test("每一个真实样本都解得开", arguments: try HookFixtures.allNames)
    func decodesEveryFixture(name: String) throws {
        let event = HookEvent.decode(try HookFixtures.data(name))
        #expect(event != nil, "样本 \(name) 解不开")
        #expect(event?.sessionID.isEmpty == false)
    }

    @Test("SessionStart 带 cwd 和 session_id —— 绑定 tab 全靠这两样")
    func sessionStart() throws {
        let event = try #require(HookEvent.decode(try HookFixtures.data("session-start")))
        #expect(event.kind == .sessionStart)
        #expect(event.cwd == "/Users/you/Desktop/Vibe/Agent灵动岛")
        #expect(event.toolName == nil)
    }

    @Test("PreToolUse 取出工具名和它在动的东西")
    func preToolUse() throws {
        let event = try #require(HookEvent.decode(try HookFixtures.data("pre-tool-use-read")))
        #expect(event.kind == .preToolUse)
        #expect(event.toolName == "Read")
        #expect(event.toolTarget == "/etc/hosts")
    }

    /// Write 的 `tool_input` 里既有 `file_path` 又有 `content`。
    /// 挑错了就会把整篇文件正文往状态带上塞。
    @Test("Write 事件挑的是文件路径，不是文件正文")
    func writePicksPathNotContent() throws {
        let event = try #require(HookEvent.decode(try HookFixtures.data("pre-tool-use-write")))
        #expect(event.toolName == "Write")
        #expect(event.toolTarget == "/tmp/spike-notification/note.txt")
    }

    /// 这个字段文档里没有，是探针抓出来的。它把「在等你批权限」和
    /// 「闲着太久提醒一声」分开 —— 只有前者该让岛快闪催人。
    @Test("Notification 带 notification_type，能认出这是权限询问")
    func notification() throws {
        let event = try #require(HookEvent.decode(try HookFixtures.data("notification-permission")))
        #expect(event.kind == .notification)
        #expect(event.notificationType == "permission_prompt")
        #expect(event.message == "Claude needs your permission")
    }

    // 这里原来还有两条 `permission_mode` → 模式档位的映射测试。
    // 那一整套（模式芯片、子代理计数）2026-08-02 删掉了，payload 里的
    // `permission_mode` 现在**故意不解析** —— 见 `HookEvent` 里那段注释。

    /// Claude Code 每次升级都往 payload 里加字段（实测 2.1.220 就比文档多出
    /// effort / prompt_id / background_tasks / session_crons）。
    /// 用严格 Codable 去接，早晚有一次升级把整条通道弄哑。
    @Test("多出来的未知字段一律无视，不影响解码")
    func toleratesUnknownFields() {
        let json = """
        {"hook_event_name":"Stop","session_id":"abc","brand_new_field_from_the_future":{"x":1}}
        """
        let event = HookEvent.decode(Data(json.utf8))
        #expect(event?.kind == .stop)
    }

    @Test("认不出的事件类型直接丢掉，不当成别的东西处理")
    func rejectsUnknownKind() {
        let json = #"{"hook_event_name":"PreCompact","session_id":"abc"}"#
        #expect(HookEvent.decode(Data(json.utf8)) == nil)
    }

    @Test("缺 session_id 的包丢掉 —— 没有它就没法绑 tab")
    func rejectsMissingSession() {
        #expect(HookEvent.decode(Data(#"{"hook_event_name":"Stop"}"#.utf8)) == nil)
        #expect(HookEvent.decode(Data(#"{"hook_event_name":"Stop","session_id":""}"#.utf8)) == nil)
    }

    @Test("整包不是 JSON 时不崩")
    func rejectsGarbage() {
        #expect(HookEvent.decode(Data("这不是 JSON".utf8)) == nil)
        #expect(HookEvent.decode(Data()) == nil)
    }
}
