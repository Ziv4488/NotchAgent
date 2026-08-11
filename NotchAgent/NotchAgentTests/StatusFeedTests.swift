//
//  StatusFeedTests.swift
//  NotchAgentTests
//

import AppKit
import Foundation
import Testing
@testable import NotchAgent

@Suite("hook 事件 → 岛上的状态与文案")
struct StatusFeedTests {

    private func signal(_ fixture: String) throws -> SessionSignal {
        let event = try #require(HookEvent.decode(try HookFixtures.data(fixture)))
        return StatusFeed.signal(for: event)
    }

    /// `SessionStart` 的意思是「进程起来了、停在提示符前」，不是「开始干活」。
    /// 这里曾经写 `.running`，于是一个什么都没干的会话状态点一直琥珀色慢呼吸、
    /// 计时一路往上走 —— 而那个数字跟任何真实的干活时长都对不上。
    @Test("SessionStart 只认领会话，不把它标成在跑")
    func sessionStart() throws {
        let signal = try signal("session-start")
        #expect(signal.claudeSessionID?.isEmpty == false)
        #expect(signal.status == nil)
        #expect(signal.demandsAttention == false)
    }

    /// 回合的真起点。探针实测：SessionStart +1.7s，UserPromptSubmit +6.5s
    /// （就是我按下回车那一刻），PreToolUse +10.6s。
    @Test("UserPromptSubmit：回合开始，转在跑")
    func userPromptSubmit() throws {
        let signal = try signal("user-prompt-submit")
        #expect(signal.status == .running)
        #expect(signal.activity == "思考中")
        #expect(signal.demandsAttention == false)
    }

    @Test("PreToolUse：收起态显示「读 hosts」这种一眼能懂的短句")
    func preToolUse() throws {
        let signal = try signal("pre-tool-use-read")
        #expect(signal.status == .running)
        #expect(signal.activity == "读 hosts")
    }

    /// 每个工具跑完都把文案清成「思考中」，状态带就会在两句话之间来回跳，
    /// 余光根本读不了。保留上一句更安静也更有信息。
    @Test("PostToolUse 不改文案，只确认还在跑 —— 免得状态带一直跳")
    func postToolUseKeepsText() throws {
        let signal = try signal("post-tool-use-read")
        #expect(signal.status == .running)
        #expect(signal.activity == nil)
    }

    @Test("权限询问：转「等你回话」并把岛推到 notice")
    func permissionPrompt() throws {
        let signal = try signal("notification-permission")
        #expect(signal.status == .waiting)
        #expect(signal.demandsAttention)
    }

    /// 闲置提醒是「你好久没理我了」，那时候用户本来就没在等结果，
    /// 让岛快闪催他是纯打扰。
    @Test("闲置提醒不催人：不进 waiting、不推 notice")
    func idleNotificationIsQuiet() {
        let json = #"{"hook_event_name":"Notification","session_id":"a","notification_type":"idle_timeout"}"#
        let signal = StatusFeed.signal(for: HookEvent.decode(Data(json.utf8))!)
        #expect(signal.status == nil)
        #expect(signal.demandsAttention == false)
    }

    @Test("Stop：这一轮完成，推 notice，但会话还活着")
    func stop() throws {
        let signal = try signal("stop")
        #expect(signal.status == .idle)
        #expect(signal.demandsAttention)
        #expect(signal.status?.isAlive == true)
    }

    /// Claude Code 每次升级都可能加新工具。那时候岛该说「工作中」，
    /// 不该显示空白，更不该崩。
    @Test("没见过的工具名降级成通用文案")
    func unknownToolDegrades() throws {
        let signal = try signal("pre-tool-use-unknown")
        #expect(signal.status == .running)
        #expect(signal.activity == "工作中")
    }

    @Test("动词表", arguments: [
        ("Read", "读"), ("Edit", "改"), ("Write", "改"), ("Bash", "跑"),
        ("Grep", "找"), ("WebSearch", "查"), ("Task", "子代理"), ("TodoWrite", "记"),
        ("mcp__linear__create_issue", "调用"), ("BrandNewTool", "工作中"),
    ])
    func verbs(tool: String, expected: String) {
        #expect(StatusFeed.verb(for: tool) == expected)
    }

    /// 状态带左侧只有约 60pt ≈ 10 个英文字符（见 IslandConstants.idleSideBleed）。
    /// 长路径和长命令必须在这里就砍短，不能指望 SwiftUI 的截断 ——
    /// 那样截出来的是「/Users/you/Desk…」，一个字的信息都没有。
    @Test("长目标砍短：路径只留文件名，命令只留前两个词")
    func shortening() {
        #expect(StatusFeed.shorten("/Users/you/Desktop/Vibe/session.ts") == "session.ts")
        #expect(StatusFeed.shorten("npm test -- --watch --coverage") == "npm test")
        #expect(StatusFeed.shorten("aVeryLongFileNameIndeed.swift").count <= 10)
        #expect(StatusFeed.shorten("aVeryLongFileNameIndeed.swift").hasSuffix("…"))
    }

    /// 我们自己截一次、SwiftUI 再尾部截一次，屏幕上会出现「读 manual-tests....」
    /// 这种四个点的怪东西 —— 实机截图里就是这么发现的。所以这里按真实字体量一遍：
    /// 只要我们截完还是放不下，就说明上限定错了。
    @Test("最长的文案也放得进状态带左半边，不会被二次截断", arguments: [
        "docs/manual-tests.md", "/Users/you/a/b/VeryLongComponentName.swift",
        "npm run test:watch -- --coverage", "src/components/Button/index.tsx",
    ])
    func fitsInTheBand(target: String) {
        let text = StatusFeed.activity(tool: "Read", target: target)
        let width = StatusFeed.defaultMeasure(text)
        #expect(width <= StatusFeed.bandTextWidth,
                "「\(text)」宽 \(width)pt，放不进 \(StatusFeed.bandTextWidth)pt")
        #expect(!text.hasSuffix("...."), "出现了二次截断的四个点")
    }

    /// 可写宽度是从岛的尺寸推出来的，不是拍脑袋定的。
    /// 哪天 `runningSideBleed` 变了而这里没跟着变，状态带就会又开始被二次截断。
    @Test("可写宽度和岛的实际尺寸对得上")
    func bandWidthMatchesTheIsland() {
        let constants = IslandConstants.default
        // 半宽 − 内边距 10 − 状态点 5 − 间距 5。
        #expect(StatusFeed.bandTextWidth == constants.runningSideBleed - 20)
    }

    /// 宽度实在不够时宁可只剩动词 —— 「读」比「读 m…」还是有用的，
    /// 而死循环或者空字符串都不行。
    @Test("宽度极窄时收敛到只剩动词，不空转也不留空串")
    func degradesToVerbOnly() {
        let text = StatusFeed.activity(tool: "Read", target: "session.ts", maxWidth: 4)
        #expect(text == "读")
    }

    @Test("没有目标时只显示动词，不留一个尾巴空格")
    func verbOnly() {
        #expect(StatusFeed.activity(tool: "Bash", target: nil) == "跑")
        #expect(StatusFeed.activity(tool: "Bash", target: "") == "跑")
        #expect(StatusFeed.activity(tool: nil, target: nil) == "工作中")
    }
}
