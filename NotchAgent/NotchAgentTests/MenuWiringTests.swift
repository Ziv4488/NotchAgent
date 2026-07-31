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

    // MARK: - 选中「Type something.」之后

    private let typing = TerminalMenu(question: "晚饭吃什么？", options: [],
                                      selected: 0, wantsTextEntry: true)

    /// **用户说的：「不能不打开在直接在上面输入吗？」**
    ///
    /// 上一版是把岛展开（收起态窗口成不了 key，不展开就打不了字）。
    /// 现在浮层自己变成输入框，岛**留在收起态**。
    @Test("终端等你打字：岛不展开，浮层变成输入框")
    func textEntryKeepsTheIslandCollapsed() {
        let m = model()
        m.debugStartSession(named: "a")
        let id = m.tabs[0].id
        m.send(.dismiss)

        m.apply(typing, to: id)
        #expect(m.state != .expanded)
        #expect(m.pendingMenu?.wantsTextEntry == true)
        #expect(m.selectedTabID == id)
        #expect(m.tabs[0].status == .waiting)
        #expect(m.tabs[0].activity == "等你打字")
    }

    /// 收起态平时**拿不了键盘**（`NotchWindow.canBecomeKey` 只在展开态为真）。
    /// 那正是用户报的「点了 Type something. 就卡住」的成因。
    /// 摆着输入框的这段时间是唯一的例外。
    @Test("摆着输入框的时候，窗口才够格拿键盘")
    func inlineEntryUnlocksTheKeyboard() {
        let m = model()
        m.debugStartSession(named: "a")
        let id = m.tabs[0].id
        m.send(.dismiss)
        #expect(m.wantsInlineTextEntry == false)

        m.apply(typing, to: id)
        #expect(m.wantsInlineTextEntry)

        m.apply(nil, to: id)
        #expect(m.wantsInlineTextEntry == false)
    }

    /// 输入态下屏幕上那些选项已经不是按钮了 —— 再按数字键是往输入框里打那个数字。
    /// 照着它们画出能点的东西，用户点一下就往框里打一个数字（实机上打出过「55534」）。
    @Test("输入态一个选项都不摆")
    func textEntryShowsNoOptions() {
        let m = model()
        m.debugStartSession(named: "a")
        let id = m.tabs[0].id
        m.send(.dismiss)

        m.apply(typing, to: id)
        #expect(m.pendingMenu?.options.isEmpty == true)
    }

    /// 展开时终端本身就在等你打字，岛不必再摆一个框 —— 两个光标抢一份键入。
    @Test("展开态照旧不给浮层")
    func textEntryGivesNoPanelWhileExpanded() {
        let m = model()
        m.debugStartSession(named: "a")
        let id = m.tabs[0].id
        m.apply(typing, to: id)
        m.send(.click)
        #expect(m.state == .expanded)
        #expect(m.pendingMenu == nil)
        #expect(m.wantsInlineTextEntry == false)
    }

    /// 框没了，键盘就该还给用户原来在用的那个 app —— 收起态的岛只在
    /// 「有个框在等他打字」的时候才占着键盘。
    @Test("框一消失就把键盘还回去")
    func endingTextEntryReleasesTheKeyboard() {
        let m = model()
        m.debugStartSession(named: "a")
        let id = m.tabs[0].id
        m.send(.dismiss)
        var released = 0
        m.onInlineEntryEnded = { released += 1 }

        m.apply(typing, to: id)
        #expect(released == 0)
        m.apply(nil, to: id)
        #expect(released == 1)
    }

    /// 普通选单来去不该动键盘归属 —— 那时候岛压根没在收键盘。
    @Test("普通选单消失不触发焦点归还")
    func ordinaryMenuDoesNotReleaseTheKeyboard() {
        let m = model()
        m.debugStartSession(named: "a")
        let id = m.tabs[0].id
        m.send(.dismiss)
        var released = 0
        m.onInlineEntryEnded = { released += 1 }

        m.apply(menu, to: id)
        m.apply(nil, to: id)
        #expect(released == 0)
    }

    /// 回车送完那一段，键盘当场还回去 —— 他已经答完了，没理由再占着。
    @Test("送出之后立刻还焦点")
    func submittingReleasesTheKeyboard() {
        let m = model()
        m.debugStartSession(named: "a")
        let id = m.tabs[0].id
        m.send(.dismiss)
        m.apply(typing, to: id)
        var released = 0
        m.onInlineEntryEnded = { released += 1 }

        m.submitInlineText("面食")
        #expect(released == 1)
    }

    /// 屏幕上印着「Esc to cancel」，岛不能在中间把它拦掉变成别的意思。
    @Test("框里按 Esc 也把键盘还回去")
    func cancellingReleasesTheKeyboard() {
        let m = model()
        m.debugStartSession(named: "a")
        let id = m.tabs[0].id
        m.send(.dismiss)
        m.apply(typing, to: id)
        var released = 0
        m.onInlineEntryEnded = { released += 1 }

        m.cancelInlineText()
        #expect(released == 1)
    }

    /// 已经展开了就别再动 tab —— 用户正看着的那个不该被换掉（同 14.8b）。
    @Test("展开态下的输入态不抢 tab")
    func textEntryDoesNotStealTheTabWhileExpanded() {
        let m = model()
        m.debugStartSession(named: "a")
        m.debugStartSession(named: "b")
        m.selectTab(m.tabs[0].id)
        #expect(m.state == .expanded)

        m.apply(typing, to: m.tabs[1].id)
        #expect(m.selectedTabID == m.tabs[0].id)
    }

    // MARK: - 接缝

    /// 浮层贴着岛的底边长出来，那条边是接缝不是外沿。岛留着圆角的话，
    /// 接缝两侧会各露一个小缺口。
    @Test("挂着浮层时，岛的底部圆角收掉")
    func islandSquaresItsBottomForThePanel() {
        let m = model()
        m.debugStartSession(named: "a")
        let id = m.tabs[0].id
        m.send(.dismiss)
        let normal = m.cornerRadii.bottom
        #expect(normal > 0)

        m.apply(menu, to: id)
        #expect(m.cornerRadii.bottom == 0)

        m.apply(nil, to: id)
        #expect(m.cornerRadii.bottom == normal)
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

    // MARK: - 往上挪一格（岛上那个「返回选项」）

    /// 用哪种编码由对面的程序决定：application cursor 模式（DECCKM）下是
    /// `ESC O A`，否则是 `ESC [ A`。发错那种会被当成一串普通字符打进输入框。
    @Test("↑ 的两种编码")
    func cursorUpEncodings() {
        #expect(TerminalKeystroke.cursorUp(applicationMode: false) == "\u{1b}[A")
        #expect(TerminalKeystroke.cursorUp(applicationMode: true) == "\u{1b}OA")
    }

    /// **这一下不能被当成 Esc。** 那会走「用户掐了这一轮」那条路，
    /// 把整道题判成取消 —— 而他只是想退回选项列表。
    @Test("↑ 不算 Esc", arguments: [false, true])
    func cursorUpIsNotEscape(applicationMode: Bool) {
        let bytes = Array(TerminalKeystroke.cursorUp(applicationMode: applicationMode).utf8)
        #expect(TerminalKeystroke.isEscape(bytes[...]) == false)
    }
}
