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

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onSend?(data)
        super.send(source: source, data: data)
    }
}
