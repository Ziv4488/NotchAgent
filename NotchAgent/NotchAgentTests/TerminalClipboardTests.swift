//
//  TerminalClipboardTests.swift
//  NotchAgentTests
//
//  岛的终端里的 ⌘C。
//

import AppKit
import SwiftTerm
import Testing
@testable import NotchAgent

/// ⌘C 只在**真的选中了东西**的时候才动剪贴板。
///
/// 用户报的是「选中岛内终端的内容，⌘C 会把整个对话复制，⌘V 再整段贴进去」。
/// 探针把这条路走了一遍（见 `ObservingTerminalView.copySelection` 的注释里那张表）：
/// 出问题的是复制 —— SwiftTerm 的 `copy(_:)` 不看 `selection.active`，而
/// `selectNone()` 只把 active 置 false、**不清 start/end**。于是按过一次 ⌘A
/// 之后，选区哪怕早就没了，⌘C 照样把上次那一整片交出去。
///
/// 这里全程用一块**私有**剪贴板，不碰系统那块 —— 跑一次测试洗掉用户手上
/// 复制的东西，是我干过一次的事。
@Suite("终端的 ⌘C")
@MainActor
struct TerminalClipboardTests {

    private func terminal(_ pasteboard: NSPasteboard) -> ObservingTerminalView {
        let view = ObservingTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.pasteboard = pasteboard
        return view
    }

    private func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("NotchAgentTests-\(UUID().uuidString)"))
    }

    /// 一下 ⌘C。走的是真实入口 `handle(_:)`（`NotchWindow.sendEvent` 调的就是它）。
    @discardableResult
    private func pressCommandC(_ view: ObservingTerminalView) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "c", charactersIgnoringModifiers: "c",
                                     isARepeat: false, keyCode: 8)!
        return view.handle(event)
    }

    @Test("选中了东西，⌘C 拿到的就是选中的那些")
    func copiesTheSelection() {
        let pasteboard = scratchPasteboard()
        let view = terminal(pasteboard)
        view.feed(text: "alpha\r\n")
        view.selectAll()

        #expect(pressCommandC(view))
        let copied = pasteboard.string(forType: .string) ?? ""
        #expect(copied.contains("alpha"))
    }

    /// **用户报的那条。** ⌘A 之后点一下别处，选区失活但 start/end 还在，
    /// 这时候 ⌘C 不该把上一次那一整片再交出去。
    @Test("选区失活之后，⌘C 不动剪贴板")
    func staleSelectionIsNotCopied() {
        let pasteboard = scratchPasteboard()
        let view = terminal(pasteboard)
        view.feed(text: "alpha\r\n")
        view.selectAll()
        pressCommandC(view)
        #expect((pasteboard.string(forType: .string) ?? "").contains("alpha"))

        // 点一下别处 —— SwiftTerm 走的就是 selectNone()。
        view.selectNone()
        pasteboard.clearContents()
        pasteboard.setString("用户后来复制的别的东西", forType: .string)

        pressCommandC(view)
        #expect(pasteboard.string(forType: .string) == "用户后来复制的别的东西")
    }

    /// 从头到尾没选过东西时，⌘C 更不能把剪贴板清空 ——
    /// SwiftTerm 的 `copy(_:)` 会无条件 `clearContents()`，实测清成了空串。
    @Test("什么都没选，⌘C 不清空剪贴板")
    func emptySelectionKeepsTheClipboard() {
        let pasteboard = scratchPasteboard()
        let view = terminal(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("原来就在剪贴板里的东西", forType: .string)

        pressCommandC(view)
        #expect(pasteboard.string(forType: .string) == "原来就在剪贴板里的东西")
    }

    /// ⌘C 无论如何都算岛接管了 —— 不能放下去让 SwiftTerm 当 Ctrl+C 发进 PTY。
    @Test("⌘C 一律不下传")
    func commandCIsAlwaysSwallowed() {
        #expect(pressCommandC(terminal(scratchPasteboard())))
    }
}
