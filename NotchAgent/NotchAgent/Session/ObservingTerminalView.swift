//
//  ObservingTerminalView.swift
//  NotchAgent
//
//  一个只多做一件事的 LocalProcessTerminalView：把发出去的字节抄送一份。
//

import AppKit
import SwiftTerm

/// 用户打进 PTY 的字节，原样抄一份给上层。
///
/// SwiftTerm 里所有去往子进程的输入 —— 键盘、粘贴、`send(txt:)` —— 最后都收敛到
/// `TerminalViewDelegate.send(source:data:)` 这一个口子上（`AppleTerminalView.send(data:)`
/// → `terminalDelegate?.send`），`LocalProcessTerminalView` 把它实现成写进伪终端。
/// 这里在转发前抄一份，就拿到了完整的输入流。
///
/// **抄送不改变任何行为**：`super` 照常调用，字节一个不少、顺序不变。
/// 「与真终端完全一致」是这个项目的硬要求，观察者不能成为例外。
final class ObservingTerminalView: LocalProcessTerminalView {

    /// 每一段发往子进程的字节。在主线程上调用（键盘事件本来就在主线程）。
    var onSend: ((ArraySlice<UInt8>) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        hideScroller()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onSend?(data)
        super.send(source: source, data: data)
    }

    /// 这一下按键岛替终端接管了吗？接管了就别再往下传。
    ///
    /// **由 `NotchWindow.sendEvent` 在最前面调，这是唯一的入口。**
    /// 不能指望 `performKeyEquivalent` —— 那一轮只跑带 ⌘ 的键，⇧← 走的是普通
    /// keyDown；也不能重写 `keyDown` —— 它在 SwiftTerm 里是 `public` 不是 `open`，
    /// 子类根本接不到。窗口的 `sendEvent` 是键盘事件进视图之前最后一个我们说了算的点。
    func handle(_ event: NSEvent) -> Bool {
        translate(event) || editingAction(event)
    }

    /// 把这一下翻译成字节写进 PTY（见 `TerminalKeystroke.shortcut`）。
    ///
    /// 发出去走 `send(txt:)`，和用户自己敲是同一个口子，所以照样被上面那个
    /// `send(source:data:)` 抄送到（Esc 的识别依赖这条）。
    private func translate(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        let modifiers = TerminalKeystroke.Modifiers(command: flags.contains(.command),
                                                    shift: flags.contains(.shift),
                                                    option: flags.contains(.option),
                                                    control: flags.contains(.control))
        guard let bytes = TerminalKeystroke.shortcut(
            keyCode: event.keyCode, modifiers: modifiers,
            applicationCursor: getTerminal().applicationCursor) else { return false }
        send(txt: bytes)
        return true
    }

    /// ⌘C / ⌘V / ⌘A。
    ///
    /// **这三个在岛里本来是死的。** SwiftTerm 把它们实现成了 `copy(_:)` /
    /// `paste(_:)` / `selectAll(_:)` 这种**动作方法** —— 正常 app 里由「编辑」菜单
    /// 的 key equivalent 沿响应链调过去。而岛是 `LSUIElement`，压根没有主菜单
    /// （只有状态栏那个 `NSStatusItem.menu`，它不参与按键派发），于是这三下
    /// 一路无人认领。这里直接调，等价于菜单本该做的事。
    /// （实测：不接管的话，在岛的终端里 ⌘V 什么都不会发生。）
    private func editingAction(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command else { return false }
        switch event.charactersIgnoringModifiers {
        case "c": copy(self); return true
        case "v": paste(self); return true
        case "a": selectAll(self); return true
        default: return false
        }
    }

    /// 把 SwiftTerm 自带的滚动条藏掉 —— 用户报的「终端内侧右边有一条透明长条」。
    ///
    /// `MacTerminalView.setup()` 无条件建一个 `NSScroller` 贴在右边、上下拉满，
    /// 并且**列数是按刨掉它之后的宽度算的**：
    /// ```
    /// reservedScrollerWidth = scroller?.isHidden == true ? 0 : scrollerWidth   // 约 15pt
    /// getEffectiveWidth(size:) = size.width - reservedScrollerWidth
    /// ```
    /// 包里没有任何地方去 hide 它，也没给出开关（`scroller` 是 private，
    /// 公开的只有 `scrollerStyle`，那个只改样式不改占位）。于是正文永远在右边
    /// 让出一条，露出底下的面板底色 —— 岛里终端本来就窄，这一条还白占一列。
    ///
    /// 藏掉之后那 15pt 直接还给列数。滚动本身不受影响：滚轮走的是
    /// `scrollWheel`，跟这个指示器是两件事。
    private func hideScroller() {
        for view in subviews where view is NSScroller {
            view.isHidden = true
        }
        needsLayout = true
    }
}
