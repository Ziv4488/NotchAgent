//
//  TerminalMenu.swift
//  NotchAgent
//
//  从终端可见屏上认出「Claude Code 正在让你选一项」。
//

import Foundation

/// 终端里正摆着的一个选择题。
///
/// **为什么要从屏幕上扒。** hook payload 里没有选项：`Notification` 只带一句
/// `message`，选项既不在 payload 里也不写进 transcript。而且 `AskUserQuestion`
/// 那种编号选单**根本不发 hook** —— 探针实测：整个回合只有 SessionStart /
/// UserPromptSubmit / PreToolUse / Notification / PostToolUse / Stop 六种事件，
/// 选项列表从头到尾没出现过。要在收起态把选项摆给用户，只剩这一条路。
struct TerminalMenu: Equatable {
    struct Option: Equatable {
        /// 屏幕上印的那个序号。按它对应的数字键就能选中。
        var number: Int
        var title: String
        /// 选项下面那行缩进的说明。权限询问没有，AskUserQuestion 有。
        var detail: String?
    }

    /// 选单上方那句问话。「Do you want to create note.txt?」「晚饭吃什么？」
    var question: String
    var options: [Option]
    /// 光标（`❯`）当前停在第几个，从 0 数起。
    var selected: Int
    /// 终端已经不在让你选，而是在等你**打字**（选了「Type something.」那一类）。
    ///
    /// 这时候选项还画在屏幕上，但它们已经不是按钮了：再按数字键是往输入框里
    /// 打那个数字。用户实机撞到过 —— 点了几下选项，输入框里出现「55534」。
    var wantsTextEntry: Bool = false

    /// 选中某一项要往 PTY 里写的字节。
    ///
    /// 直接打那个数字 —— 两种选单实测都认。不用「方向键挪过去再回车」是因为
    /// 那要求我们对光标位置的判断绝对正确，错一格就选错项；数字键是绝对寻址。
    func keystroke(for option: Option) -> String { "\(option.number)" }
}

extension TerminalMenu {

    /// 认不出来就返回 nil，**岛什么都不做**。
    ///
    /// 这条要求高于「尽量认出来」：Claude Code 每次升级都可能改这些字，
    /// 而显示半个错的选单比不显示危险得多 —— 用户会照着它按键。
    static func parse(_ lines: [String]) -> TerminalMenu? {
        guard let footer = footerIndex(in: lines) else { return nil }

        // 输入态：**一个选项都不往上带**。屏幕上那些行还在，但它们已经不是按钮了，
        // 谁要是照着它画出能点的东西，点下去就是往输入框里打数字。
        if isTextEntry(footerText(lines, at: footer)) {
            return TerminalMenu(question: "", options: [], selected: 0, wantsTextEntry: true)
        }

        // 序号是从 1 往下升的，所以「1.」那行就是选单的顶。
        // 从页脚往上找它，顺带把扫描范围框住 —— 选单不会有几十行高，
        // 扫太远只会把上文里碰巧长得像选项的行卷进来。
        let floor = max(0, footer - Limits.bodyLines)
        var top: Int?
        var row = footer - 1
        while row >= floor {
            if let option = option(in: lines[row]), option.number == 1 {
                top = row
                break
            }
            row -= 1
        }
        guard let top else { return nil }

        var options: [Option] = []
        var selected = 0
        for index in top..<footer {
            let line = lines[index]
            if let option = option(in: line) {
                // 序号必须是 1、2、3…… 连着来。跳号说明我们框错了范围。
                guard option.number == options.count + 1 else { return nil }
                if line.contains(Marker.cursor) { selected = options.count }
                options.append(Option(number: option.number, title: option.title, detail: nil))
            } else if !options.isEmpty, let detail = detail(in: line),
                      options[options.count - 1].detail == nil {
                options[options.count - 1].detail = detail
            }
        }

        // 一个选项不构成选择题；超过九个就没有数字键可按了（两位数要连按，
        // 中间那一下会被当成一次选择）。两种情况都不如交给终端。
        guard (2...Limits.maxOptions).contains(options.count) else { return nil }
        guard let question = question(above: top, in: lines) else { return nil }

        return TerminalMenu(question: question, options: options, selected: selected)
    }

    // MARK: - 单行识别

    private enum Marker {
        /// 光标。注意它也出现在输入提示符上（`❯ 用 Write 工具…`），
        /// 所以不能拿它当「这是个选项」的依据，只能拿来定位选中项。
        static let cursor = "❯"
        /// 画框和分隔线用的字符。这些行在选单中间会出现（第 4、5 项之间就有一条），
        /// 不能因为撞见它就以为选单到头了。
        static let rules = CharacterSet(charactersIn: "─╌│╭╮╰╯━┈┌┐└┘ ")
    }

    private enum Limits {
        static let bodyLines = 30
        static let maxOptions = 9
        static let questionSearch = 4
    }

    /// 页脚：那行「Esc to cancel · …」。
    ///
    /// **只拿它确认「这确实是个选单」，不解析它。** 两种选单的页脚措辞不一样
    /// （权限询问是「Esc to cancel · Tab to amend」，AskUserQuestion 是
    /// 「Enter to select · ↑/↓ to navigate · Esc to cancel」），共同点只有前半句。
    private static func footerIndex(in lines: [String]) -> Int? {
        lines.indices.reversed().first { footerText(lines, at: $0).contains("Esc to cancel") }
    }

    /// 页脚那一行，**连着下一行一起看**。
    ///
    /// 收起态下岛里的终端只有六十出头列，长页脚会折行。实机上抓到过：
    /// ```
    /// Enter to select · ↑/↓ to navigate · ctrl+g to edit in Vim · Esc
    /// to cancel
    /// ```
    /// 没有任何**一行**含「Esc to cancel」，`parse` 于是一路返回 nil ——
    /// 选中「Type something.」之后岛什么都认不出来，只好继续摆着那些已经
    /// 不是按钮的选项。样本见 `Fixtures/screens/type-something-narrow.txt`。
    ///
    /// 空白压成单个空格：屏幕右边是补齐的空格，直接拼会得到「Esc      to cancel」。
    private static func footerText(_ lines: [String], at index: Int) -> String {
        let pair = index + 1 < lines.count ? [lines[index], lines[index + 1]] : [lines[index]]
        return pair.joined(separator: " ").split(separator: " ").joined(separator: " ")
    }

    /// 页脚上多出来的那句 Vim 提示 —— 只有当前这一项变成输入框时才会出现。
    ///
    /// 实测（`scripts/spike-textentry.py` + `Fixtures/screens/type-something.txt`）：
    /// 选中「Type something.」之后页脚从
    /// `Enter to select · ↑/↓ to navigate · Esc to cancel` 变成
    /// `Enter to select · ↑/↓ to navigate · ctrl+g to edit in Vim · Esc to cancel`。
    /// 前半截**没变**，所以不能靠「有没有 Enter to select」来分，只能认这一句。
    ///
    /// 认错了的代价是安全的一侧：岛会展开、把键盘交还给终端，用户照样能操作。
    /// 认不出来才是危险的 —— 那就回到用户报的那个「点选项变成打数字」。
    private static func isTextEntry(_ footer: String) -> Bool {
        footer.contains("edit in Vim")
    }

    /// `❯ 1. Yes` / `  2. 川菜小炒` → (2, "川菜小炒")。
    private static func option(in line: String) -> (number: Int, title: String)? {
        var rest = Substring(line)
        rest = rest.drop { $0 == " " }
        if rest.hasPrefix(Marker.cursor) {
            rest = rest.dropFirst(Marker.cursor.count).drop { $0 == " " }
        }

        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2, let number = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        guard rest.hasPrefix(".") else { return nil }

        let title = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (number, title)
    }

    /// 选项底下那行缩进的说明。分隔线和空行不算。
    private static func detail(in line: String) -> String? {
        // 至少缩进到序号右边，否则它是别的东西而不是这个选项的说明。
        guard line.prefix(4).allSatisfy({ $0 == " " }) else { return nil }
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.rangeOfCharacter(from: Marker.rules.inverted) != nil else { return nil }
        return text
    }

    /// 选单上方最近的那句人话。
    private static func question(above top: Int, in lines: [String]) -> String? {
        var row = top - 1
        while row >= 0, row > top - Limits.questionSearch {
            let text = lines[row].trimmingCharacters(in: .whitespaces)
            // 空行和分隔线跳过去，接着往上找。
            if !text.isEmpty, text.rangeOfCharacter(from: Marker.rules.inverted) != nil {
                return text
            }
            row -= 1
        }
        return nil
    }
}
