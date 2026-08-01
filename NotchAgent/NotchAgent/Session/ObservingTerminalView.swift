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

    /// ⌘C 往哪儿写。生产代码就是系统剪贴板，单测换成一块私有的，
    /// 免得跑一遍测试就把用户手上的剪贴板洗了。
    var pasteboard: NSPasteboard = .general

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
        case "c": copySelection(); return true
        case "v": paste(self); return true
        case "a": selectAll(self); return true
        default: return false
        }
    }

    /// ⌘C。**不能直接用 SwiftTerm 的 `copy(_:)`。**
    ///
    /// 它是这么写的：
    /// ```swift
    /// let str = selection.getSelectedText()   // 没看 selection.active
    /// clipboard.clearContents()
    /// clipboard.setString(str, forType: .string)
    /// ```
    /// 选区**失活之后 start/end 并不清零**（`selectNone` 只把 active 置 false），
    /// 于是「上一次选过什么」会一直留着。实测这么一串（探针 `/tmp/notch-probe.log`）：
    ///
    /// | 做了什么 | selectionActive | ⌘C 拿到 |
    /// |---|---|---|
    /// | 什么都没选 | false | **把剪贴板清空了** |
    /// | 鼠标拖一段 | true | 那 11 个字 ✓ |
    /// | 再单击一下 | false | 还是那 11 个字（旧的） |
    /// | ⌘A | true | 整屏 502 字 |
    /// | 再单击一下 | false | **还是那 502 字** ← 用户报的 |
    ///
    /// 用户先按过 ⌘A（或者拖出去过一次选区），之后不管选没选中，⌘C 一律
    /// 复制整个对话，⌘V 再把它整段贴回输入框 —— 出问题的是复制，不是粘贴。
    ///
    /// 这里改成看 `getSelection()`：它是 SwiftTerm 里**唯一**会检查
    /// `selection.active` 的取值口。没有活着的选区就一个字都不动 ——
    /// 真终端里 ⌘C 也是这样，不会顺手把你剪贴板清了。
    private func copySelection() {
        guard let text = getSelection(), !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
