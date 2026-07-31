//
//  KeyRoutingTests.swift
//  NotchAgentTests
//
//  展开态下哪些键归岛、哪些归终端。
//

import AppKit
import SwiftUI
import Testing
@testable import NotchAgent

@Suite("展开态的按键归属")
@MainActor
struct KeyRoutingTests {

    private typealias Action = IslandWindowController.KeyAction
    private typealias Key = IslandWindowController.KeyCode

    private func action(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [],
                        canCancelNewTask: Bool = false) -> Action {
        IslandWindowController.action(keyCode: keyCode, modifiers: modifiers,
                                      canCancelNewTask: canCancelNewTask)
    }

    /// **这是整个改动的要害。** Claude Code 的选单底下就印着「Esc to cancel」，
    /// 岛在中间拦一道的话，按下去是岛收起来了 —— 屏幕上写的字成了假的。
    /// 中断当前回合、连按两下退回上一条，也全靠这个键。
    @Test("Esc 一律放行给终端")
    func escapeGoesToTheTerminal() {
        #expect(action(Key.escape) == .passThrough)
        #expect(action(Key.escape, .shift) == .passThrough)
    }

    /// ⇧Tab 是 Claude Code 切权限模式的键，岛没有理由代劳 ——
    /// 代劳过一次（转发 CSI Z），多一层转发只多一处会错的地方。
    @Test("⇧Tab 一律放行给终端")
    func shiftTabGoesToTheTerminal() {
        #expect(action(48, .shift) == .passThrough)
    }

    @Test("⌘W 收起岛")
    func commandWDismisses() {
        #expect(action(Key.w, .command) == .dismiss)
    }

    /// 光按 W 是在终端里打字。加了别的修饰键（⌥⌘W、⇧⌘W）也不是我们的键位，
    /// 拦下来只会让用户的自定义快捷键莫名失灵。
    @Test("只有干净的 ⌘W 才收起", arguments: [
        NSEvent.ModifierFlags(), .shift, .option, [.command, .shift], [.command, .option],
    ] as [NSEvent.ModifierFlags])
    func onlyPlainCommandW(modifiers: NSEvent.ModifierFlags) {
        #expect(action(Key.w, modifiers) == .passThrough)
    }

    /// caps lock 亮着、或者键盘上报了 numericPad 之类的标志位时，
    /// 原始 modifierFlags 里会混进这些位。拿它直接比相等，⌘W 就失灵了。
    @Test("caps lock 开着时 ⌘W 照样管用")
    func ignoresIrrelevantFlags() {
        #expect(action(Key.w, [.command, .capsLock]) == .dismiss)
    }

    /// 新建表单里 first responder 是 SwiftUI 的输入框，根本没有终端在接键，
    /// 这时候 Esc 退出表单不抢任何人的东西。
    @Test("新建表单里 Esc 退出表单")
    func escapeCancelsTheForm() {
        #expect(action(Key.escape, canCancelNewTask: true) == .cancelNewTask)
    }

    /// 一个 tab 都没有时新建表单是唯一能显示的东西，退出去岛就空了。
    /// 那种情况调用方传 false，Esc 仍然放行。
    @Test("退不出去的表单不吃 Esc")
    func escapeIsNotSwallowedWhenTheFormCannotClose() {
        #expect(action(Key.escape, canCancelNewTask: false) == .passThrough)
    }

    /// 剩下的每一个键都必须原样进终端 —— 终端里的交互要和真终端一模一样。
    @Test("普通按键一概不拦", arguments: [
        (UInt16(0), NSEvent.ModifierFlags()),           // A
        (UInt16(36), NSEvent.ModifierFlags()),          // Return
        (UInt16(48), NSEvent.ModifierFlags()),          // Tab
        (UInt16(18), NSEvent.ModifierFlags()),          // 1 —— 权限选单靠它选项
        (UInt16(126), NSEvent.ModifierFlags()),         // ↑
        (UInt16(8), NSEvent.ModifierFlags.control),     // ⌃C
        (Key.w, NSEvent.ModifierFlags()),               // 光是 W
    ])
    func everythingElsePassesThrough(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        #expect(action(keyCode, modifiers) == .passThrough)
    }
}

@Suite("收起时的焦点归还")
struct FocusHandoffTests {

    /// 正常情况：焦点在 A 时展开岛，中途没人来抢，收起还给 A。
    @Test("没人来抢的话，收起还给展开前那个 app")
    func restoresWhenNobodyElseTookOver() {
        var handoff = FocusHandoff()
        let app = NSRunningApplication.current
        handoff.remember(app)
        #expect(handoff.appToRestore() === app)
    }

    /// 这就是用户报的那个 bug：焦点在 A 时展开，中途自己点去了 B，
    /// 一收起人被弹回 A —— 他刚选好的窗口被抢走了。
    @Test("展开期间用户自己切走了，收起时谁都别动")
    func doesNotStealFocusBack() {
        var handoff = FocusHandoff()
        handoff.remember(NSRunningApplication.current)
        handoff.someoneElseTookOver()
        #expect(handoff.appToRestore() == nil)
    }

    /// 用户可能来回切好几次：A → 展开 → B → C → 收起。
    /// 每一次别人抢前台都作废，不是只作废第一次。
    @Test("来回切好几个 app 也一样作废")
    func staysForgottenAcrossSeveralSwitches() {
        var handoff = FocusHandoff()
        handoff.remember(NSRunningApplication.current)
        handoff.someoneElseTookOver()
        handoff.someoneElseTookOver()
        #expect(handoff.appToRestore() == nil)
    }

    /// 记录只对这一次展开有效。留着的话，下一次「不该还」的收起会把上一次的
    /// 记录翻出来用，bug 换个时机重现。
    @Test("还过一次就清空，不会在下一次收起时重放")
    func forgetsAfterHandingBack() {
        var handoff = FocusHandoff()
        handoff.remember(NSRunningApplication.current)
        _ = handoff.appToRestore()
        #expect(handoff.appToRestore() == nil)
    }

    /// 作废之后再展开一次是全新的一轮，该记得住。
    @Test("作废之后重新展开，照样记得住新的那个")
    func remembersAgainAfterANewExpansion() {
        var handoff = FocusHandoff()
        handoff.remember(NSRunningApplication.current)
        handoff.someoneElseTookOver()
        _ = handoff.appToRestore()

        let app = NSRunningApplication.current
        handoff.remember(app)
        #expect(handoff.appToRestore() === app)
    }

    @Test("从没记过东西时收起不炸")
    func emptyHandoffIsHarmless() {
        var handoff = FocusHandoff()
        #expect(handoff.appToRestore() == nil)
    }

    /// 用户切走过一次（记录作废），又从那个 app 点回岛上 ——
    /// 收起时该还给他刚才那个，而不是谁都不还。
    @Test("作废之后他又点回岛上，那就记下他现在待的那个")
    func remembersWhenTheUserClicksBack() {
        var handoff = FocusHandoff()
        handoff.remember(NSRunningApplication.current)
        handoff.someoneElseTookOver()

        let app = NSRunningApplication.current
        handoff.rememberIfEmpty(app)
        #expect(handoff.appToRestore() === app)
    }

    /// 展开那一刻记下的那个才是这一轮的起点，点击不该把它顶掉。
    @Test("已经记着东西时不覆盖")
    func doesNotOverwriteAnExistingRecord() {
        var handoff = FocusHandoff()
        let first = NSRunningApplication.current
        handoff.remember(first)
        handoff.rememberIfEmpty(nil)
        #expect(handoff.appToRestore() === first)
    }
}

@Suite("改名输入框的宽度")
struct RenameFieldWidthTests {

    /// 名字删空时输入框会缩成零宽：光标消失，谁都不知道自己还在编辑状态。
    @Test("空草稿也留得下光标")
    func emptyDraftKeepsMinimumWidth() {
        #expect(TabStrip.fieldWidth(for: "") >= TabStrip.Layout.minFieldWidth)
    }

    @Test("名字越长框越宽")
    func growsWithTheDraft() {
        #expect(TabStrip.fieldWidth(for: "一个相当长的会话名字") > TabStrip.fieldWidth(for: "a"))
    }

    /// 量宽度和渲染必须用同一个字体，否则量出来的数不作数 ——
    /// 状态带就是在这上面栽过一次（见 StatusFeedTests）。
    @Test("量宽度用的就是 tab 标题的字体")
    func measuresWithTheRenderedFont() {
        #expect(TabStrip.titleFont == NSFont.systemFont(ofSize: 11, weight: .medium))
    }

    /// `measuredWidth` 里往 `[.font:]` 塞过一个**不是字体**的东西：
    /// `TabStrip` 是 `View`，裸写 `font` 会解析成没被调用的 `View.font(_:)` 修饰器，
    /// 字典值是 `Any` 所以编译通过，运行时 AppKit 一问 `pointSize` 就整个 app 炸掉。
    /// 这条测试会真的去量一次，塞错东西就在这里死。
    @MainActor
    @Test("tab 条量宽度不会因为塞错字体而崩")
    func measuresTheStripWithoutCrashing() {
        let tabs = [
            IslandTab(title: "a", kind: .cli, status: .running, accent: .red),
            IslandTab(title: "一个长得多的名字", kind: .cli, status: .done, accent: .blue),
        ]
        #expect(TabStrip.measuredWidth(for: tabs) > TabStrip.measuredWidth(for: [tabs[0]]))
    }

    /// 关闭按钮平时是透明的，但**始终占着位置**。量宽度时漏掉它，
    /// 收起态的岛就比 tab 条窄，最后那个 tab 会被切掉一块。
    @Test("量宽度把关闭按钮算进去")
    func chipWidthIncludesTheCloseButton() {
        let tab = IslandTab(title: "a", kind: .cli, status: .running, accent: .red)
        let text = ("a" as NSString).size(withAttributes: [.font: TabStrip.titleFont]).width
        let withoutClose = TabStrip.Layout.chipHPadding * 2 + TabStrip.Layout.iconSize + 5 + ceil(text)
        #expect(TabStrip.chipWidth(for: tab) >= withoutClose + TabStrip.Layout.closeSize)
    }

    /// 拖拽换位是拿这个宽度算「越过邻居没有」的，它必须和 tab 条量出来的一致。
    @Test("tab 条的宽度就是各芯片宽度加起来")
    func stripWidthIsTheSumOfItsChips() {
        let tabs = [
            IslandTab(title: "a", kind: .cli, status: .running, accent: .red),
            IslandTab(title: "第二个", kind: .cli, status: .done, accent: .blue),
        ]
        let chips = tabs.reduce(0) { $0 + TabStrip.chipWidth(for: $1) + TabStrip.Layout.tabGap }
        #expect(TabStrip.measuredWidth(for: tabs) > chips)
    }
}
