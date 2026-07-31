//
//  SessionWiringTests.swift
//  NotchAgentTests
//
//  hook 信号落到岛上之后，tab 和岛的状态对不对。
//

import SwiftUI
import Testing
@testable import NotchAgent

@Suite("会话信号 → 岛")
@MainActor
struct SessionWiringTests {

    private func modelWithOneTab(status: IslandTab.Status = .running) -> (IslandModel, UUID) {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        model.debugStartSession(named: "refactor-auth")
        let id = model.tabs[0].id
        if status != .running { model.apply(SessionSignal(status: sessionStatus(status)), to: id) }
        return (model, id)
    }

    private func sessionStatus(_ status: IslandTab.Status) -> SessionStatus {
        switch status {
        case .running: .running
        case .waiting: .waiting
        case .done: .idle
        case .ended: .finished(0)
        }
    }

    @Test("工具事件把收起态文案换成「在干什么」")
    func activityLandsOnTab() {
        let (model, id) = modelWithOneTab()
        model.apply(SessionSignal(status: .running, activity: "读 session.ts"), to: id)
        #expect(model.tabs[0].activity == "读 session.ts")
    }

    @Test("权限询问：tab 转等待、岛进 notice、打上未读")
    func waitingRaisesNotice() {
        let (model, id) = modelWithOneTab()
        model.apply(SessionSignal(status: .waiting, activity: "等你回话", demandsAttention: true), to: id)
        #expect(model.tabs[0].status == .waiting)
        #expect(model.tabs[0].unread)
        #expect(model.state == .notice)
    }

    /// 岛已经展开、而且看的就是这个 tab —— 人正盯着屏幕，
    /// 再打一个「有新消息」的红点是纯噪音。
    @Test("正看着的那个 tab 完成时不打未读")
    func doesNotNagWhenWatching() {
        let (model, id) = modelWithOneTab()
        model.selectTab(id)
        model.send(.click)
        #expect(model.state == .expanded)

        model.apply(SessionSignal(status: .idle, demandsAttention: true), to: id)
        #expect(model.tabs[0].unread == false)
        #expect(model.state == .expanded, "不该打断展开")
    }

    @Test("没在看的时候完成，要打未读并把岛推到 notice")
    func nagsWhenNotWatching() {
        let (model, id) = modelWithOneTab()
        model.apply(SessionSignal(status: .idle, demandsAttention: true), to: id)
        #expect(model.tabs[0].unread)
        #expect(model.state == .notice)
    }

    /// 状态带右边显示的是「这一轮跑了多久」，不是「这个 tab 开了多久」。
    /// 后者对「要不要去看它」没有任何帮助。
    @Test("重新开跑时计时归零")
    func restartResetsTheClock() async throws {
        let (model, id) = modelWithOneTab()
        model.apply(SessionSignal(status: .idle), to: id)
        let finishedAt = model.tabs[0].startedAt
        try await Task.sleep(for: .milliseconds(30))

        model.apply(SessionSignal(status: .running), to: id)
        #expect(model.tabs[0].startedAt > finishedAt)
    }

    @Test("同一轮里的连续工具事件不会一直重置计时")
    func staysRunningWithoutResetting() async throws {
        let (model, id) = modelWithOneTab()
        let startedAt = model.tabs[0].startedAt
        try await Task.sleep(for: .milliseconds(30))
        model.apply(SessionSignal(status: .running, activity: "读 a.ts"), to: id)
        model.apply(SessionSignal(status: .running, activity: "改 b.ts"), to: id)
        #expect(model.tabs[0].startedAt == startedAt)
    }

    @Test("事件里的模式落到芯片上")
    func modeLandsOnChip() {
        let (model, id) = modelWithOneTab()
        model.apply(SessionSignal(mode: .plan), to: id)
        #expect(model.tabs[0].usage.mode == .plan)
    }

    @Test("对不上任何 tab 的信号被忽略，不会误改别人的状态")
    func ignoresUnknownTab() {
        let (model, _) = modelWithOneTab()
        model.apply(SessionSignal(status: .waiting, demandsAttention: true), to: UUID())
        #expect(model.tabs[0].status == .running)
        #expect(model.tabs[0].unread == false)
    }

    // MARK: - 进程状态

    @Test("进程退出：tab 转已结束并标成可继续")
    func processExitDetaches() {
        let (model, id) = modelWithOneTab()
        model.apply(SessionStatus.finished(0), to: id)
        #expect(model.tabs[0].status == .ended)
        #expect(model.tabs[0].isDetached)
    }

    /// 起不来的原因要留在界面上。只把 tab 变灰，用户无从知道发生了什么。
    @Test("进程失败时把原因留在 tab 上")
    func failureKeepsTheReason() {
        let (model, id) = modelWithOneTab()
        model.apply(SessionStatus.failed("进程异常中断"), to: id)
        #expect(model.tabs[0].status == .ended)
        #expect(model.tabs[0].activity == "进程异常中断")
    }

    @Test("会话层的状态收敛到岛上的四种", arguments: [
        (SessionStatus.starting, IslandTab.Status.running),
        (.running, .running),
        (.waiting, .waiting),
        (.idle, .done),
        (.finished(0), .ended),
        (.finished(3), .ended),
        (.failed("x"), .ended),
    ])
    func statusMapping(session: SessionStatus, tab: IslandTab.Status) {
        #expect(IslandTab.Status(session) == tab)
    }

    @Test("活着的判定：只有退出和失败算死")
    func aliveness() {
        #expect(SessionStatus.starting.isAlive)
        #expect(SessionStatus.running.isAlive)
        #expect(SessionStatus.waiting.isAlive)
        #expect(SessionStatus.idle.isAlive, "Stop 只是一轮结束，进程还在")
        #expect(SessionStatus.finished(0).isAlive == false)
        #expect(SessionStatus.failed("x").isAlive == false)
    }

    // MARK: - tab 生命周期

    @Test("关掉最后一个 tab 后岛回到 idle")
    func closingLastTabReturnsToIdle() {
        let (model, id) = modelWithOneTab()
        model.closeTab(id)
        #expect(model.tabs.isEmpty)
        #expect(model.state == .idle)
    }

    @Test("关掉选中的 tab 后选中落到还剩下的那个上")
    func closingSelectedMovesSelection() {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        model.debugStartSession(named: "a")
        model.debugStartSession(named: "b")
        let first = model.tabs[0].id
        model.selectTab(first)
        model.closeTab(first)
        #expect(model.tabs.count == 1)
        #expect(model.selectedTabID == model.tabs[0].id)
    }

    // MARK: - 拖着 tab 换位置

    @Test("拖到后面一格")
    func movingTabForward() {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        model.debugStartSession(named: "a")
        model.debugStartSession(named: "b")
        model.moveTab(from: 0, to: 1)
        #expect(model.tabs.map(\.title) == ["b", "a"])
    }

    /// 换了位不能顺手把「正看着哪个」也换掉 —— 用户只是在整理顺序。
    @Test("换位不改变选中的是谁")
    func movingKeepsTheSelection() {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        model.debugStartSession(named: "a")
        model.debugStartSession(named: "b")
        model.debugStartSession(named: "c")
        let selected = model.tabs[2].id
        model.selectTab(selected)

        model.moveTab(from: 2, to: 0)
        #expect(model.tabs[0].id == selected)
        #expect(model.selectedTabID == selected)
    }

    /// 拖到两头之外时视图层照样会调进来（手还在往外拉）。
    @Test("越界的换位是空操作", arguments: [(0, 5), (-1, 0), (0, 0)])
    func outOfRangeMoveIsHarmless(source: Int, destination: Int) {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        model.debugStartSession(named: "a")
        model.debugStartSession(named: "b")
        model.moveTab(from: source, to: destination)
        #expect(model.tabs.map(\.title) == ["a", "b"])
    }

    /// 同一个项目每次开都该是同一个颜色，不然 tab 条上认不出老朋友。
    @Test("tab 底色按目录固定，同一个目录永远同一个颜色")
    func accentIsStable() {
        #expect(IslandModel.accent(for: "/tmp/a") == IslandModel.accent(for: "/tmp/a"))
    }

    // MARK: - 没有 runtime 时的降级

    /// 预览、单元测试、以及 `-debugState` 起的调试形态都没有 runtime。
    /// 那时候一切仍要能跑，只是不起真进程。
    @Test("没接 runtime 时不去起进程，也不写盘")
    func degradesWithoutRuntime() {
        let model = IslandModel(geometry: FakeScreenGeometry.macBook14)
        #expect(model.runtime == nil)
        model.startTask(in: ProjectDirectory(path: "/tmp/x", lastUsed: .now, hasSessions: false),
                        instruction: "跑测试")
        #expect(model.tabs.count == 1)
        #expect(model.selectedTabHasLiveTerminal == false)
        // 停止在没有会话时退回本地行为，不该崩。
        model.interruptSelectedTask()
        #expect(model.tabs[0].status == .done)
    }
}
