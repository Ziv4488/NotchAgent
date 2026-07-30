//
//  IslandStateTests.swift
//  NotchAgentTests
//
//  四态状态机。每个 (state, event) 组合都要有明确结论。
//

import Testing
@testable import NotchAgent

private let idle = IslandContext(runningCount: 0, unreadCount: 0)
private let running1 = IslandContext(runningCount: 1, unreadCount: 0)
private let unread1 = IslandContext(runningCount: 0, unreadCount: 1)
private let bothBusy = IslandContext(runningCount: 1, unreadCount: 1)

struct IslandStateTests {

    // MARK: - 用户交互

    @Test("任何形态点一下都进展开", arguments: IslandState.allCases)
    func clickAlwaysExpands(state: IslandState) {
        #expect(reduce(state, .click, idle) == .expanded)
        #expect(reduce(state, .click, bothBusy) == .expanded)
    }

    @Test("点开 tab 必然处于展开", arguments: IslandState.allCases)
    func tabOpenedAlwaysExpands(state: IslandState) {
        #expect(reduce(state, .tabOpened, unread1) == .expanded)
    }

    @Test("收起后落回自然形态：无事回 idle、有跑回 running、有未读回 notice")
    func dismissFallsBack() {
        #expect(reduce(.expanded, .dismiss, idle) == .idle)
        #expect(reduce(.expanded, .dismiss, running1) == .running)
        #expect(reduce(.expanded, .dismiss, unread1) == .notice)
    }

    @Test("未读优先于运行中 —— 提醒去看比显示进度重要")
    func unreadOutranksRunning() {
        #expect(reduce(.expanded, .dismiss, bothBusy) == .notice)
    }

    @Test("notice 收到 dismiss 但仍有未读时留在 notice —— 通知常驻")
    func noticeStaysWhileUnread() {
        #expect(reduce(.notice, .dismiss, unread1) == .notice)
        #expect(reduce(.notice, .dismiss, bothBusy) == .notice)
    }

    @Test("未读清空后 notice 才回落")
    func noticeLeavesOnlyWhenRead() {
        #expect(reduce(.notice, .allRead, idle) == .idle)
        #expect(reduce(.notice, .allRead, running1) == .running)
    }

    // MARK: - 后台事件不打断展开

    @Test("展开时任何后台事件都不打断", arguments: [
        IslandEvent.sessionStarted, .sessionProgress, .sessionStopped, .allRead, .lastSessionEnded
    ])
    func expandedIsNotInterrupted(event: IslandEvent) {
        #expect(reduce(.expanded, event, idle) == .expanded)
        #expect(reduce(.expanded, event, bothBusy) == .expanded)
    }

    // MARK: - 会话事件

    @Test("会话开跑：idle → running")
    func sessionStartedFromIdle() {
        #expect(reduce(.idle, .sessionStarted, running1) == .running)
    }

    @Test("会话开跑时若仍有未读，留在 notice 不被冲掉")
    func sessionStartedKeepsNotice() {
        #expect(reduce(.notice, .sessionStarted, bothBusy) == .notice)
    }

    @Test("会话完成一律弹通知（展开态除外）", arguments: [IslandState.idle, .running, .notice])
    func sessionStoppedRaisesNotice(state: IslandState) {
        #expect(reduce(state, .sessionStopped, unread1) == .notice)
    }

    @Test("进展事件只刷新文案，不改变形态", arguments: [IslandState.idle, .running, .notice])
    func progressIsInert(state: IslandState) {
        let context: IslandContext = switch state {
        case .idle: idle
        case .running: running1
        default: unread1
        }
        #expect(reduce(state, .sessionProgress, context) == state)
    }

    @Test("最后一个会话被关掉：无未读回 idle，有未读留 notice")
    func lastSessionEnded() {
        #expect(reduce(.running, .lastSessionEnded, idle) == .idle)
        #expect(reduce(.notice, .lastSessionEnded, unread1) == .notice)
    }

    // MARK: - 全组合兜底

    @Test("任何 (state, event, context) 组合都不会崩，且结果落在四态内")
    func totality() {
        let events: [IslandEvent] = [.sessionStarted, .sessionProgress, .sessionStopped,
                                     .tabOpened, .click, .dismiss, .allRead, .lastSessionEnded]
        let contexts = [idle, running1, unread1, bothBusy]
        for state in IslandState.allCases {
            for event in events {
                for context in contexts {
                    let next = reduce(state, event, context)
                    #expect(IslandState.allCases.contains(next))
                }
            }
        }
    }

    @Test("状态机是幂等的：同一事件重复投递不会漂移")
    func idempotent() {
        let events: [IslandEvent] = [.sessionProgress, .dismiss, .click, .allRead]
        let contexts = [idle, running1, unread1, bothBusy]
        for state in IslandState.allCases {
            for event in events {
                for context in contexts {
                    let once = reduce(state, event, context)
                    let twice = reduce(once, event, context)
                    #expect(once == twice, "\(state) + \(event)")
                }
            }
        }
    }
}
