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
