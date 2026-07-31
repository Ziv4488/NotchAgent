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

    /// **这条是整个功能存在的理由。** `AskUserQuestion` 只发 `PreToolUse`，
    /// **不发 `Notification`**（探针实测）—— 没有任何事件说「它停下来等你了」。
    /// 光靠 hook，岛会一直显示「在跑」，而终端其实卡在那儿等人。
    /// 看到选单就等于收到一次「等你回话」。
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

    /// 岛下面只有一块地方摆浮层，所以问话的那个 tab 得先被选中。
    /// 收起态下自动切过去 —— 「谁在问」岛已经知道了，让用户自己去找是多余的一步。
    @Test("收起态：谁在问就切到谁")
    func menuSelectsItsOwnTab() {
        let m = model()
        m.debugStartSession(named: "a")
        m.debugStartSession(named: "b")
        m.selectTab(m.tabs[0].id)
        m.send(.dismiss)

        m.apply(menu, to: m.tabs[1].id)
        #expect(m.selectedTabID == m.tabs[1].id)
        #expect(m.pendingMenu != nil)
    }

    /// 展开时**不切**：用户正看着某个 tab 的终端，底下换成另一个会话，
    /// 是把他从他手上的事情里拽走。
    @Test("展开态：别的 tab 问话不抢走当前 tab")
    func menuDoesNotStealTheTabWhileExpanded() {
        let m = model()
        m.debugStartSession(named: "a")
        m.debugStartSession(named: "b")
        m.selectTab(m.tabs[0].id)
        #expect(m.state == .expanded)

        m.apply(menu, to: m.tabs[1].id)
        #expect(m.selectedTabID == m.tabs[0].id)
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

    // MARK: - 按 Esc 不选

    /// **用户报的 bug。** 出选项后按 Esc 不选，琥珀色呼吸灯一直亮。
    ///
    /// 探针实测：Esc 之后 Claude Code 一个 hook 都不发，没有任何东西会来纠正状态。
    @Test("Esc 取消：不再是「在跑」")
    func escapeEndsTheTurn() {
        let m = model()
        m.debugStartSession(named: "a")
        let id = m.tabs[0].id
        m.send(.dismiss)
        m.apply(menu, to: id)
        #expect(m.tabs[0].status == .waiting)

        m.cancelTurn(id)
        #expect(m.tabs[0].status == .done)
        #expect(m.tabs[0].activity == nil)
        #expect(m.tabs[0].unread == false)
        #expect(m.pendingMenu == nil)
    }

    /// 这条盯的是**顺序**：Esc 之后半秒，扫描才发现选单没了。
    /// 那一拍不能再把状态交回 `.running` —— 那正是 bug 的最后一步。
    @Test("Esc 之后扫描报「选单没了」，不该复活成在跑")
    func lateScanDoesNotRevive() {
        let m = model()
        m.debugStartSession(named: "a")
        let id = m.tabs[0].id
        m.send(.dismiss)
        m.apply(menu, to: id)

        m.cancelTurn(id)
        m.apply(nil, to: id)          // 慢半拍的那次扫描
        #expect(m.tabs[0].status == .done)
    }

    /// 岛也该跟着回到静默 —— 没有未读、没有在跑，就没有理由继续挂着通知态。
    @Test("Esc 取消之后岛回到 idle")
    func escapeLetsTheIslandSettle() {
        let m = model()
        m.debugStartSession(named: "a")
        let id = m.tabs[0].id
        m.send(.dismiss)
        m.apply(menu, to: id)
        #expect(m.state == .notice)

        m.cancelTurn(id)
        #expect(m.state == .idle)
    }

    @Test("对不存在的 tab 按 Esc 不炸")
    func cancellingUnknownTabIsHarmless() {
        let m = model()
        m.debugStartSession(named: "a")
        m.cancelTurn(UUID())
        #expect(m.tabs[0].status == .running)
    }
}

/// 打进 PTY 的按键里认出 Esc。
@Suite("认出 Esc")
struct TerminalKeystrokeTests {

    @Test("单独一个 0x1b 就是 Esc")
    func plainEscape() {
        #expect(TerminalKeystroke.isEscape([0x1b][...]))
    }

    /// 方向键、Delete 键都是 `0x1b` 打头。只看首字节的话，
    /// 用户在选单里按上下箭头挑选项，会被当成「他取消了」。
    @Test("0x1b 打头的别的键不算", arguments: [
        [0x1b, 0x5b, 0x41] as [UInt8],          // ↑
        [0x1b, 0x4f, 0x42],                     // ↓（application cursor 模式）
        [0x1b, 0x5b, 0x33, 0x7e],               // Delete
        Array("\u{1b}[13u".utf8),               // Kitty 编码的回车
    ])
    func otherEscapePrefixedKeys(bytes: [UInt8]) {
        #expect(TerminalKeystroke.isEscape(bytes[...]) == false)
    }

    /// Kitty 键盘协议下 Esc 是 `ESC [ 27 u`。用哪种编码由对面的程序决定，
    /// 不由我们 —— 两种都得认。
    @Test("Kitty 协议的 Esc")
    func kittyEscape() {
        #expect(TerminalKeystroke.isEscape(Array("\u{1b}[27u".utf8)[...]))
        #expect(TerminalKeystroke.isEscape(Array("\u{1b}[27;1u".utf8)[...]))
    }

    /// ⌃Esc 是另一个键位，不该跟着把这一轮判成结束了。
    @Test("带修饰键的不算")
    func modifiedKittyEscape() {
        #expect(TerminalKeystroke.isEscape(Array("\u{1b}[27;5u".utf8)[...]) == false)
    }

    @Test("普通字符与回车不算", arguments: ["1", "\r", "y", "晚饭"])
    func ordinaryInput(text: String) {
        #expect(TerminalKeystroke.isEscape(Array(text.utf8)[...]) == false)
    }

    @Test("空的不算")
    func empty() {
        #expect(TerminalKeystroke.isEscape([UInt8]()[...]) == false)
    }
}
