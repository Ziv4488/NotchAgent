//
//  ShellShimTests.swift
//  NotchAgentTests
//
//  hook 通道的第一环：岛里敲 `claude` 必须落在包装脚本上。
//

import Foundation
import Testing
@testable import NotchAgent

/// 这些测试**真的起 zsh**，不是照着字符串比对。
///
/// 08-08 到 08-11 之间 hook 通道整条静默断掉，靠的就是没人真跑过这一步：
/// 包装脚本写对了、PATH 也确实带上了，可 `path_helper` 和用户的 `.zshrc`
/// 都在我们之后动 PATH，包装脚本被挤到最后一位，`claude` 解析到真身，
/// `--settings` 没加上，六个 hook 一条都不发。岛于是永远不显示执行状态、
/// 也不通知。**只有把 shell 真起起来才看得见这件事。**
///
/// 原来 `docs/manual-tests.md` §18.6 是一行手测（「在岛里的 shell 里
/// `which claude`」）。它可以自动化，于是自动化。
@Suite("shell shim")
struct ShellShimTests {

    // MARK: - 夹具

    /// 一个跟真实情况同构的局：用户的 rc 往 PATH 最前面塞一个自己的 `claude`。
    private struct Fixture {
        let root: URL
        let binDir: URL
        let zdotDir: URL
        let userHome: URL
        /// 用户自己装的那个 claude（`~/.local/bin/claude` 的替身）。
        let decoy: URL

        init(userRC: String) throws {
            let manager = FileManager.default
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "notch-shim-\(UUID().uuidString)")
            binDir = root.appending(path: "bin")
            zdotDir = root.appending(path: "zdotdir")
            userHome = root.appending(path: "home")
            let decoyDir = userHome.appending(path: ".local/bin")
            decoy = decoyDir.appending(path: "claude")

            try manager.createDirectory(at: decoyDir, withIntermediateDirectories: true)
            try "#!/bin/sh\nexit 0\n".write(to: decoy, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: decoy.path)
            try userRC.replacingOccurrences(of: "<decoy>", with: decoyDir.path)
                .write(to: userHome.appending(path: ".zshrc"), atomically: true, encoding: .utf8)

            try ShellShim.install(binDir: binDir, zdotDir: zdotDir)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }

        /// 起一个**交互式登录 shell**，跟岛里那个一样，回答一句话。
        ///
        /// 三个都不能省：`-l` 才会跑 `/etc/zprofile` 的 `path_helper`，
        /// `-i` 才会跑 `.zshrc`，两者正是把包装脚本挤下去的那两只手。
        func ask(_ question: String, withZDotDir: Bool = true) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-i", "-c", question]
            var environment = [
                "HOME": userHome.path,
                "TERM": "xterm-256color",
                // 岛拼给 PTY 的那个 PATH：包装脚本的目录排在最前面。
                "PATH": binDir.path + ":/usr/bin:/bin:/usr/sbin:/sbin",
            ]
            if withZDotDir {
                environment["ZDOTDIR"] = zdotDir.path
                environment["NOTCH_USER_ZDOTDIR"] = userHome.path
            }
            process.environment = environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - 会红的那一条

    /// **回滚验证过**：把 `ZDOTDIR` 这一层摘掉（`withZDotDir: false`，等价于
    /// 08-08 到 08-11 的实现），答案就是 decoy —— 见下面那条对照测试。
    @Test("岛里的 claude 落在包装脚本上，赢过用户 rc 的 PATH 前置")
    func wrapperWinsOverUserRC() throws {
        let fixture = try Fixture(userRC: #"export PATH="<decoy>:$PATH""#)
        defer { fixture.cleanUp() }

        let resolved = try fixture.ask("command -v claude")
        #expect(resolved == fixture.binDir.appending(path: "claude").path)
    }

    /// 上面那条不是碰巧绿的：同一个夹具、只摘掉 ZDOTDIR，`claude` 就归了用户。
    ///
    /// 这一条**替代了「把修复回滚一遍」那个动作**，而且它长在测试里，
    /// 下次有人手滑把 ZDOTDIR 去掉，红的会是上面那条。
    @Test("只前置 PATH 的老办法确实赢不了 —— 用户的 claude 会胜出")
    func pathPrependAloneLoses() throws {
        let fixture = try Fixture(userRC: #"export PATH="<decoy>:$PATH""#)
        defer { fixture.cleanUp() }

        let resolved = try fixture.ask("command -v claude", withZDotDir: false)
        #expect(resolved == fixture.decoy.path)
    }

    /// `.zlogin` 在 `.zshrc` 之后跑。把 PATH 写在那儿的人不多，但有。
    @Test("用户把 PATH 写在 .zlogin 里也压不住包装脚本")
    func wrapperWinsOverZLogin() throws {
        let fixture = try Fixture(userRC: "")
        defer { fixture.cleanUp() }
        try #"export PATH="<decoy>:$PATH""#
            .replacingOccurrences(of: "<decoy>",
                                  with: fixture.userHome.appending(path: ".local/bin").path)
            .write(to: fixture.userHome.appending(path: ".zlogin"),
                   atomically: true, encoding: .utf8)

        let resolved = try fixture.ask("command -v claude")
        #expect(resolved == fixture.binDir.appending(path: "claude").path)
    }

    // MARK: - 用户的 shell 还得是他自己的

    /// 间接层的代价必须为零：用户 rc 里定义的东西一样都不能少。
    @Test("用户的 .zshrc 照样原样跑")
    func userRCStillRuns() throws {
        let fixture = try Fixture(userRC: "export NOTCH_TEST_MARK=用户的rc跑过了")
        defer { fixture.cleanUp() }

        #expect(try fixture.ask("printf '%s' \"$NOTCH_TEST_MARK\"") == "用户的rc跑过了")
    }

    /// 用户的 rc 不存在时不能报错、更不能让 shell 起不来。
    @Test("用户没有 .zshrc 也照常起 shell")
    func toleratesMissingUserRC() throws {
        let fixture = try Fixture(userRC: "")
        defer { fixture.cleanUp() }
        try FileManager.default.removeItem(at: fixture.userHome.appending(path: ".zshrc"))

        #expect(try fixture.ask("printf ok") == "ok")
    }

    /// 前置是幂等的：岛里再开一层 zsh，PATH 里不该越堆越多。
    @Test("嵌套 shell 不会把 bin 目录堆一堆")
    func prependIsIdempotent() throws {
        let fixture = try Fixture(userRC: "")
        defer { fixture.cleanUp() }

        let counted = try fixture.ask(
            "zsh -l -i -c 'print -r -- $PATH' | tr ':' '\\n' | grep -c -F -x -- \(ShellShim.quoted(fixture.binDir.path))")
        #expect(counted == "1")
    }

    // MARK: - 装出来的东西本身

    @Test("包装脚本可执行")
    func wrapperIsExecutable() throws {
        let fixture = try Fixture(userRC: "")
        defer { fixture.cleanUp() }

        let wrapper = fixture.binDir.appending(path: "claude").path
        #expect(FileManager.default.isExecutableFile(atPath: wrapper))
    }

    /// 只有 zsh 有 `ZDOTDIR`。给 bash 设一个是没用的噪音。
    @Test("只有 zsh 走 ZDOTDIR")
    func onlyZshUsesZDotDir() {
        #expect(ShellShim.usesZDotDir(shell: "/bin/zsh"))
        #expect(ShellShim.usesZDotDir(shell: "/opt/homebrew/bin/zsh"))
        #expect(!ShellShim.usesZDotDir(shell: "/bin/bash"))
        #expect(!ShellShim.usesZDotDir(shell: "/opt/homebrew/bin/fish"))
    }

    /// `Application Support` 里有空格，路径不引起来的话 rc 直接语法错，
    /// 整个 shell 起不来 —— 比 hook 断掉还严重。
    @Test("带空格和单引号的路径也引得住")
    func quotesAwkwardPaths() {
        #expect(ShellShim.quoted("/a/Application Support/bin") == "'/a/Application Support/bin'")
        #expect(ShellShim.quoted("/a/it's/bin") == #"'/a/it'\''s/bin'"#)
    }
}
