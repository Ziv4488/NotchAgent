//
//  TerminalKeystroke.swift
//  NotchAgent
//
//  认出用户往 PTY 里打的 Esc。
//

import Foundation

/// 打进伪终端的按键里，我们只关心一个：**Esc**。
///
/// **为什么非要认它**：探针实测（`scripts/spike-escape.py`），选单出现后按 Esc
/// 取消，Claude Code **一个 hook 都不发** —— 没有 `PostToolUse`，没有 `Stop`，
/// 等 25 秒也没有。而选单一消失，岛按「答完了」把状态交回 `.running`，
/// 于是那个 tab 永远琥珀色慢呼吸、计时一路往上涨。用户报的就是这个。
///
/// 事件通道在这条路上是哑的，屏幕上剩下的又只有 `User declined to answer questions`
/// 这种会随版本变的英文句子。唯一稳的信号是**用户自己按下的那个键** ——
/// 它经过我们的视图（见 `ObservingTerminalView`），跟 Claude Code 的界面文案无关，
/// 跟它哪个版本也无关。
///
/// Esc 在 Claude Code 里的含义是明确的、写在 `CLISession.interrupt` 的注释里的：
/// 「停下这一轮但留着会话」。所以看见 Esc 就等于看见这一轮结束了。
enum TerminalKeystroke {

    /// 按一下 ↑ 要写进 PTY 的字节。
    ///
    /// **两种编码由对面的程序说了算**：终端处在 application cursor 模式
    /// （DECCKM，`ESC [ ? 1 h`）时是 `ESC O A`，否则是 `ESC [ A`。
    /// 发错那种，接收方可能把它当成一串普通字符打进输入框里。
    /// 当前模式从 `Terminal.applicationCursor` 读，不要猜。
    ///
    /// 注意这**不是** Esc：`isEscape` 只认单独一个 `0x1b`，所以这一下不会被
    /// 当成「用户掐了这一轮」（见 `TerminalKeystrokeTests`）。
    static func cursorUp(applicationMode: Bool) -> String {
        applicationMode ? "\u{1b}OA" : "\u{1b}[A"
    }

    /// ⌘← / ⌘→ 要写进 PTY 的字节。返回 `nil` 表示这一下不归我们管，原样放过去。
    ///
    /// macOS 的文本框里 ⌘← 是「跳到行首」，用户在岛的终端里自然也这么按。
    /// 但**终端本身没有「行首」这个概念** —— 光标归对面那个程序管，我们能做的
    /// 只有把这一下翻译成对面认得的按键。Claude Code 的输入框是 Ink 写的，
    /// 走 readline 那一套：`Ctrl+A` 行首、`Ctrl+E` 行尾。
    ///
    /// **只认「光按着 ⌘」。** ⌘⇧← 在 macOS 里是「选到行首」，而 Ink 的输入框
    /// 根本没有选区这个东西 —— 没有能翻译过去的键，硬发一个 Ctrl+A 会变成
    /// 「跳到行首但没选中」，比不动更让人误会。所以带 ⇧ 的原样放行。
    static func lineJump(keyCode: UInt16, commandOnly: Bool) -> String? {
        guard commandOnly else { return nil }
        switch keyCode {
        case KeyCode.leftArrow: return "\u{01}"    // Ctrl+A
        case KeyCode.rightArrow: return "\u{05}"   // Ctrl+E
        default: return nil
        }
    }

    enum KeyCode {
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
    }

    /// 这一段字节是不是「用户按了 Esc」。
    ///
    /// 两种编码都要认，因为用哪种由**对面的程序**决定，不由我们：
    ///
    /// - 传统编码：单独一个 `0x1b`。
    /// - Kitty 键盘协议：`ESC [ 27 u`（开了 disambiguate 之后 SwiftTerm 就发这个）。
    ///
    /// 方向键也是 `0x1b` 打头（`ESC [ A`），所以传统那种必须**整段只有这一个字节**
    /// 才算，不能只看首字节。
    static func isEscape(_ bytes: ArraySlice<UInt8>) -> Bool {
        if bytes.count == 1, bytes.first == 0x1b { return true }
        return isKittyEscape(bytes)
    }

    /// `ESC [ 27 u` 或 `ESC [ 27 ; 1 u`。
    ///
    /// 带修饰键的（`ESC [ 27 ; 5 u` = ⌃Esc）不算：那是另一个键位，
    /// 不该跟着把这一轮判成结束了。
    private static func isKittyEscape(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard bytes.count >= 5, bytes.first == 0x1b else { return false }
        let body = Array(bytes.dropFirst())
        guard body.first == UInt8(ascii: "["), body.last == UInt8(ascii: "u") else { return false }
        let fields = String(decoding: body.dropFirst().dropLast(), as: UTF8.self)
            .split(separator: ";", omittingEmptySubsequences: false)
        guard fields.first == "27" else { return false }
        switch fields.count {
        case 1: return true
        case 2: return fields[1] == "1"   // 1 = 没按任何修饰键
        default: return false
        }
    }
}
