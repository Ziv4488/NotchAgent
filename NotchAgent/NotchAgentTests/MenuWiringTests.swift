//
//  MenuWiringTests.swift
//  NotchAgentTests
//
//  终端上的选择题落到岛上。
//

import Foundation
import Testing
@testable import NotchAgent

@Suite("选择题落到岛上")
@MainActor
struct MenuWiringTests {

    private func model() -> IslandModel {
        IslandModel(geometry: FakeScreenGeometry.macBook14)
    }

    private let menu = TerminalMenu(
        question: "晚饭吃什么？",
        options: [
            .init(number: 1, title: "麻辣香锅", detail: "重口味"),
            .init(number: 2, title: "日式拉面", detail: nil),
            .init(number: 3, title: "轻食沙拉", detail: nil),
        ],
        selected: 0)

    /// **这条是整个功能存在的理由。** `AskUserQuestion` 那种编号选单
    /// 一个 hook 都不发（探针实测），光靠事件岛会一直显示「在跑」，
    /// 而终端其实卡在那儿等人。看到选单就等于收到一次「等你回话」。
    @Test("看到选单就催人：转等待、标未读、推 notice")
    func menuDemandsAttention() {
        let m = model()
        m.debugStartSession(named: "a")
        let id = m.tabs[0].id

        m.apply(menu, to: id)
        #expect(m.tabs[0].status == .waiting)
        #expect(m.tabs[0].unread)
        #expect(m.state == .notice)
        #expect(m.tabs[0].activity == "晚饭吃什么？")
    }

    @Test("选单没了，「等你回话」跟着摘掉")
    func menuGoingAwayClearsWaiting() {
        let m = model()
        m.debugStartSession(named: "a")
        let id = m.tabs[0].id

        m.apply(menu, to: id)
        m.apply(nil, to: id)
        #expect(m.tabs[0].status != .waiting)
        #expect(m.tabs[0].activity == nil)
        #expect(m.pendingMenu == nil)
    }

    /// 用户说的：只在收起/通知态出现。展开时终端本身就摆着那个选单，
    /// 再叠一层是同一份东西显示两遍。
    @Test("展开态不给浮层")
    func noPanelWhileExpanded() {
        let m = model()
        m.debugStartSession(named: "a")
        let id = m.tabs[0].id
        m.apply(menu, to: id)
        #expect(m.pendingMenu != nil)

        m.send(.click)
        #expect(m.state == .expanded)
        #expect(m.pendingMenu == nil)
    }

    /// 浮层只跟着选中的那个 tab。别的 tab 在问话，得先切过去。
    @Test("浮层只显示选中那个 tab 的选单")
    func panelFollowsTheSelectedTab() {
        let m = model()
        m.debugStartSession(named: "a")
        m.debugStartSession(named: "b")
        m.selectTab(m.tabs[0].id)
        m.send(.dismiss)

        m.apply(menu, to: m.tabs[1].id)
        #expect(m.pendingMenu == nil)

        m.selectTab(m.tabs[1].id)
        m.send(.dismiss)
        #expect(m.pendingMenu != nil)
    }

    /// 人正看着的时候弹出来的问题，不该在他收起岛之后还挂着一条未读。
    @Test("看着的时候弹出来，不标未读")
    func noUnreadWhileWatching() {
        let m = model()
        m.debugStartSession(named: "a")
        let id = m.tabs[0].id
        m.selectTab(id)
        #expect(m.state == .expanded)

        m.apply(menu, to: id)
        #expect(m.tabs[0].unread == false)
    }

    /// 岛上印的序号必须和终端里的一致 —— 岛自己重新编号的话，
    /// 用户看着岛按键盘会按错。
    @Test("选中一项就是把那个数字打进 PTY")
    func choosingSendsTheNumber() throws {
        let parsed = try #require(TerminalMenu.parse(try ScreenFixtures.lines("ask-user-question")))
        #expect(parsed.keystroke(for: parsed.options[2]) == "3")
        #expect(parsed.options[2].number == 3)
    }

    /// 没接 runtime（预览、单测）时点选项不该崩。
    @Test("没有 runtime 时点选项是无害的")
    func choosingWithoutRuntimeIsHarmless() {
        let m = model()
        m.debugStartSession(named: "a")
        let id = m.tabs[0].id
        m.apply(menu, to: id)
        m.choose(menu.options[0], in: id)
        // 点完**不清掉浮层** —— 清不清由下一次扫描说了算。
        // 那一下万一没被接受，岛该继续显示它，而不是自作主张宣布问题解决了。
        #expect(m.pendingMenu != nil)
    }

    @Test("给不存在的 tab 报选单不炸")
    func unknownTabIsHarmless() {
        let m = model()
        m.debugStartSession(named: "a")
        m.apply(menu, to: UUID())
        #expect(m.pendingMenu == nil)
    }
}
