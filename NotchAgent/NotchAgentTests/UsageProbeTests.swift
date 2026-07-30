//
//  UsageProbeTests.swift
//  NotchAgentTests
//

import Foundation
import Testing
@testable import NotchAgent

@Suite("用量三项的真实来源")
struct UsageProbeTests {

    // MARK: - 上下文

    private func transcript(_ lines: [String]) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "notch-tx-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// 缓存命中的 token 照样占着上下文窗口，三项都要算进去。
    /// 只算 `input_tokens` 的话，一个跑了半天的会话会显示成「上下文 0%」。
    @Test("上下文 = input + cache_read + cache_creation")
    func sumsAllInputTokens() throws {
        let path = try transcript([
            #"{"type":"assistant","message":{"usage":{"input_tokens":2,"cache_read_input_tokens":39998,"cache_creation_input_tokens":20000}}}"#
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        // 60000 / 200000 = 30%
        #expect(UsageProbe.contextRatio(transcriptPath: path) == 0.3)
    }

    @Test("取最后一条 assistant 消息，不是第一条")
    func usesTheLatestMessage() throws {
        let path = try transcript([
            #"{"type":"assistant","message":{"usage":{"input_tokens":10000}}}"#,
            #"{"type":"user","message":{"content":"再来"}}"#,
            #"{"type":"assistant","message":{"usage":{"input_tokens":100000}}}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(UsageProbe.contextRatio(transcriptPath: path) == 0.5)
    }

    @Test("没有 assistant 消息（会话刚开）时是「不知道」，不是 0%")
    func unknownBeforeFirstReply() throws {
        let path = try transcript([#"{"type":"user","message":{"content":"你好"}}"#])
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(UsageProbe.contextRatio(transcriptPath: path) == nil)
    }

    @Test("文件不存在时是「不知道」，不崩")
    func missingTranscript() {
        #expect(UsageProbe.contextRatio(transcriptPath: "/tmp/definitely-not-here.jsonl") == nil)
    }

    /// transcript 会长到几十兆，整篇读进来会卡住主线程。只读尾部意味着
    /// 尾部可能从半行开始 —— 那半行必须被安静地跳过。
    @Test("只读尾部：被截断的半行不会让解析失败")
    func toleratesTruncatedFirstLine() throws {
        let path = try transcript([
            String(repeating: "x", count: 400),
            #"{"type":"assistant","message":{"usage":{"input_tokens":20000}}}"#,
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(UsageProbe.contextRatio(transcriptPath: path, tailBytes: 120) == 0.1)
    }

    @Test("超过预算时封顶到 100%，不会画出超出槽外的条")
    func capsAtFull() throws {
        let path = try transcript([
            #"{"type":"assistant","message":{"usage":{"input_tokens":900000}}}"#
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(UsageProbe.contextRatio(transcriptPath: path) == 1)
    }

    // MARK: - 账号限额

    private func config(fiveHour: Double, sevenDay: Double, fetchedAt: Date) -> Data {
        let json: [String: Any] = [
            "cachedUsageUtilization": [
                "fetchedAtMs": fetchedAt.timeIntervalSince1970 * 1000,
                "utilization": [
                    "five_hour": ["utilization": fiveHour, "resets_at": "2026-07-31T09:59:59Z"],
                    "seven_day": ["utilization": sevenDay, "resets_at": "2026-08-06T00:59:59Z"],
                    "seven_day_opus": NSNull(),
                ],
            ],
            // 真实的 ~/.claude.json 里还有一堆别的东西，不该干扰解析。
            "projects": ["/tmp/a": ["history": []]],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test("从 Claude Code 自己的缓存里读出 5h 与周额度，百分数换算成 0...1")
    func parsesLimits() {
        let limits = UsageProbe.parseLimits(config(fiveHour: 88, sevenDay: 19, fetchedAt: .now))
        #expect(limits?.fiveHour == 0.88)
        #expect(limits?.weekly == 0.19)
    }

    @Test("字段缺失或结构对不上时返回 nil，不是 0")
    func missingLimits() {
        #expect(UsageProbe.parseLimits(Data(#"{}"#.utf8)) == nil)
        #expect(UsageProbe.parseLimits(Data(#"{"cachedUsageUtilization":{}}"#.utf8)) == nil)
        #expect(UsageProbe.parseLimits(Data("坏数据".utf8)) == nil)
    }

    /// Claude Code 只在它自己需要时刷新那份缓存（比如你开了 `/usage`）。
    /// 隔一天读到的数字完全不作数，而用户会照着它决定还能不能接着干活。
    @Test("缓存太旧就当不知道，宁可显示横线也不显示过期的百分比")
    func staleLimitsAreDiscarded() {
        let now = Date()
        let fresh = UsageProbe.parseLimits(config(fiveHour: 88, sevenDay: 19,
                                                  fetchedAt: now.addingTimeInterval(-60)))
        #expect(UsageProbe.fresh(fresh, now: now) != nil)

        let old = UsageProbe.parseLimits(config(fiveHour: 88, sevenDay: 19,
                                                fetchedAt: now.addingTimeInterval(-3600)))
        #expect(UsageProbe.fresh(old, now: now) == nil)
    }

    @Test("没有 fetchedAtMs 的旧格式一律当过期")
    func missingTimestampIsStale() {
        let json = #"{"cachedUsageUtilization":{"utilization":{"five_hour":{"utilization":10},"seven_day":{"utilization":20}}}}"#
        let limits = UsageProbe.parseLimits(Data(json.utf8))
        #expect(limits != nil)
        #expect(UsageProbe.fresh(limits) == nil)
    }

    /// 分母是 Claude Code 的自动压缩阈值，不是模型的真实上下文窗口
    /// （Opus 5 报的是 1,000,000）。用真实窗口算，岛上的数会和终端里的对不上。
    @Test("上下文分母用的是自动压缩阈值 20 万")
    func budgetMatchesClaudeCode() {
        #expect(UsageProbe.contextBudget == 200_000)
    }
}

@Suite("子代理计数")
@MainActor
struct SubagentTests {

    private func signal(_ kind: HookEvent.Kind, tool: String?) -> SessionSignal {
        StatusFeed.signal(for: HookEvent(kind: kind, sessionID: "s", toolName: tool))
    }

    /// 子代理没有自己的 hook —— 它就是 `Task` 工具。开一个 +1，回来一个 -1。
    @Test("Task 开始 +1、结束 -1，别的工具不动")
    func countsTaskTool() {
        #expect(signal(.preToolUse, tool: "Task").subagentDelta == 1)
        #expect(signal(.postToolUse, tool: "Task").subagentDelta == -1)
        #expect(signal(.preToolUse, tool: "Read").subagentDelta == 0)
    }

    /// 岛可能是在几个子代理跑到一半时才启动的，那时只会收到它们的 PostToolUse。
    /// 减到负数会显示成「-2 个子代理」。
    @Test("只收到结束事件时不会减成负数")
    func neverGoesNegative() {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        model.debugStartSession(named: "a")
        let id = model.tabs[0].id
        for _ in 0..<(model.tabs[0].usage.subagents + 3) {
            model.apply(SessionSignal(subagentDelta: -1), to: id)
        }
        #expect(model.tabs[0].usage.subagents == 0)
    }

    @Test("开三个回一个，净增两个")
    func accumulates() {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        // debugStartSession 造的假会话自带 2 个子代理（给预览用），所以量的是增量。
        model.debugStartSession(named: "a")
        let id = model.tabs[0].id
        let before = model.tabs[0].usage.subagents

        for _ in 0..<3 { model.apply(SessionSignal(subagentDelta: 1), to: id) }
        model.apply(SessionSignal(subagentDelta: -1), to: id)
        #expect(model.tabs[0].usage.subagents == before + 2)
    }
}
