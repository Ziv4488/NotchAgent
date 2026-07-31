//
//  TerminalMenuTests.swift
//  NotchAgentTests
//
//  从真实屏幕快照里认选单。
//

import Foundation
import Testing
@testable import NotchAgent

/// 两份 fixture 都是**跑真的 claude、经 `CLISession.visibleLines()` 取出来的**，
/// 不是手写的。手写的样本只会验证我对格式的想象。
enum ScreenFixtures {
    static func lines(_ name: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/screens/\(name).txt")
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }
}

@Suite("认出终端里的选择题")
struct TerminalMenuTests {

    // MARK: - 权限询问

    @Test("权限询问：三个选项、问句、光标在第一项")
    func permissionPrompt() throws {
        let menu = try #require(TerminalMenu.parse(try ScreenFixtures.lines("permission-write")))
        #expect(menu.question == "Do you want to create note.txt?")
        #expect(menu.options.map(\.number) == [1, 2, 3])
        #expect(menu.options[0].title == "Yes")
        #expect(menu.options[2].title == "No")
        #expect(menu.selected == 0)
    }

    /// 这一屏上方就有一行 `  1 hi` —— 文件 diff 的行号。
    /// 它长得很像选项，但没有那个点，不能被收进来。
    @Test("diff 里的行号不会被当成选项")
    func diffLineNumbersAreNotOptions() throws {
        let menu = try #require(TerminalMenu.parse(try ScreenFixtures.lines("permission-write")))
        #expect(menu.options.count == 3)
        #expect(menu.options.allSatisfy { $0.title != "hi" })
    }

    // MARK: - AskUserQuestion

    @Test("AskUserQuestion：五个选项，前三个各带一行说明")
    func askUserQuestion() throws {
        let menu = try #require(TerminalMenu.parse(try ScreenFixtures.lines("ask-user-question")))
        #expect(menu.question == "晚饭吃什么？")
        #expect(menu.options.map(\.number) == [1, 2, 3, 4, 5])
        #expect(menu.options[0].title == "日式拉面")
        #expect(menu.options[0].detail?.hasPrefix("一碗热汤面") == true)
        #expect(menu.selected == 0)
    }

    /// 第 4 项和第 5 项之间隔着一条分隔线。撞见它就以为选单到头的话，
    /// 「Chat about this」会丢掉。
    @Test("选项中间的分隔线不截断选单")
    func separatorInsideTheMenu() throws {
        let menu = try #require(TerminalMenu.parse(try ScreenFixtures.lines("ask-user-question")))
        #expect(menu.options.last?.title == "Chat about this")
    }

    /// 「Type something.」自己没有说明，不能把下一行分隔线塞给它当说明。
    @Test("没有说明的选项就是没有")
    func optionsWithoutDetail() throws {
        let menu = try #require(TerminalMenu.parse(try ScreenFixtures.lines("ask-user-question")))
        #expect(menu.options[3].title == "Type something.")
        #expect(menu.options[3].detail == nil)
        #expect(menu.options[4].detail == nil)
    }

    /// 输入提示符那行也是 `❯` 开头（`❯ 用 AskUserQuestion`）。
    /// 拿 `❯` 当「这是选项」的依据，问句和选项都会串位。
    @Test("输入提示符上的 ❯ 不影响选中项的判断")
    func promptCursorIsNotTheMenuCursor() throws {
        let menu = try #require(TerminalMenu.parse(try ScreenFixtures.lines("ask-user-question")))
        #expect(menu.selected == 0)
    }

    // MARK: - 认不出来的一律返回 nil

    /// 这条是整套东西的底线。Claude Code 每次升级都可能改这些字，
    /// 那时候岛该安静地什么都不做 —— 显示半个错的选单比不显示危险得多，
    /// 用户会照着它按键。
    @Test("认不出来就返回 nil", arguments: [
        [],
        ["随便一行输出"],
        ["❯ 用 Write 工具写点东西", "⏺ 好的"],
        // 有页脚没选项
        ["Esc to cancel · Tab to amend"],
        // 有选项没页脚：可能只是正文里的编号列表
        ["要点如下：", "❯ 1. 第一条", "  2. 第二条"],
        // 只有一个选项，不构成选择题
        ["确认吗？", "❯ 1. 好", "Esc to cancel"],
        // 序号跳了，说明框错了范围
        ["选一个", "❯ 1. a", "  3. b", "Esc to cancel"],
        // 选项上面没有问句
        ["❯ 1. a", "  2. b", "Esc to cancel"],
    ] as [[String]])
    func returnsNilWhenUnsure(lines: [String]) {
        #expect(TerminalMenu.parse(lines) == nil)
    }

    /// 光标不在第一项时也要认对 —— 用户按了下箭头之后就是这样。
    @Test("光标停在第几项就报第几项")
    func tracksTheCursor() {
        let menu = TerminalMenu.parse([
            "删掉这个文件吗？",
            "  1. 删",
            "❯ 2. 不删",
            "Esc to cancel",
        ])
        #expect(menu?.selected == 1)
    }

    /// 选项超过九个就没有数字键可按了：两位数要连按两下，
    /// 中间那一下会先被当成一次选择。那种情况交给终端。
    @Test("超过九个选项不接管")
    func tooManyOptions() {
        var lines = ["挑一个"]
        for n in 1...12 { lines.append("  \(n). 第 \(n) 项") }
        lines.append("Esc to cancel")
        #expect(TerminalMenu.parse(lines) == nil)
    }

    @Test("选中一项就是打那个数字")
    func keystrokeIsTheNumber() throws {
        let menu = try #require(TerminalMenu.parse(try ScreenFixtures.lines("permission-write")))
        #expect(menu.keystroke(for: menu.options[2]) == "3")
    }
}
