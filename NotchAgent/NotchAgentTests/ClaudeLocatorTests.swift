//
//  ClaudeLocatorTests.swift
//  NotchAgentTests
//

import Testing
@testable import NotchAgent

@Suite("找 claude 可执行文件")
struct ClaudeLocatorTests {

    @Test("按 PATH 顺序找，第一个命中的算数")
    func findsFirstOnPath() {
        let locator = ClaudeLocator(
            loginPath: { "/a:/b:/c" },
            isExecutable: { $0 == "/b/claude" || $0 == "/c/claude" })
        #expect(locator.locate() == .found(path: "/b/claude", searchPath: "/a:/b:/c"))
    }

    @Test("PATH 里没有就报找不到，并把找过的 PATH 一起带出来给用户看")
    func reportsNotFound() {
        let locator = ClaudeLocator(loginPath: { "/a:/b" }, isExecutable: { _ in false })
        #expect(locator.locate() == .notFound(searchPath: "/a:/b"))
    }

    @Test("手填的路径优先于自动搜索")
    func overrideWins() {
        let locator = ClaudeLocator(
            override: "/custom/claude",
            loginPath: { "/a" },
            isExecutable: { $0 == "/a/claude" || $0 == "/custom/claude" })
        #expect(locator.locate() == .found(path: "/custom/claude", searchPath: "/a"))
    }

    /// 用户填过路径、后来把 claude 卸了或换了装法，这时候拿着坏路径去 spawn
    /// 只会得到一个「起不来」的空 tab。宁可退回自动搜索。
    @Test("手填的路径已失效时退回自动搜索，而不是拿着坏路径去起进程")
    func staleOverrideFallsBack() {
        let locator = ClaudeLocator(
            override: "/gone/claude",
            loginPath: { "/a" },
            isExecutable: { $0 == "/a/claude" })
        #expect(locator.locate() == .found(path: "/a/claude", searchPath: "/a"))
    }

    /// 取 PATH 用的是**交互式**登录 shell（`-ilc`），因为很多人的 PATH 是在 .zshrc 里拼的。
    /// 代价是用户 rc 里的 echo、fortune、版本管理器的提示会一起混进 stdout。
    @Test("从被 rc 输出污染的 shell 结果里挑出 PATH")
    func parsesPathFromNoisyOutput() {
        let output = """
        Welcome back!
        nvm: using node v20
        /opt/homebrew/bin:/usr/bin:/bin

        """
        #expect(ClaudeLocator.parsePath(output) == "/opt/homebrew/bin:/usr/bin:/bin")
    }

    @Test("shell 什么都没吐出来时用兜底 PATH，兜底里必须有常见的包管理器目录")
    func fallsBackWhenShellSaysNothing() {
        let locator = ClaudeLocator(loginPath: { nil }, isExecutable: { _ in false })
        guard case .notFound(let searchPath) = locator.locate() else {
            Issue.record("应该是找不到"); return
        }
        #expect(searchPath == ClaudeLocator.fallbackPath)
        #expect(searchPath.contains("/opt/homebrew/bin"))
        #expect(searchPath.contains("/usr/local/bin"))
    }

    @Test("PATH 段末尾带斜杠也能拼对，不会拼出双斜杠错过文件")
    func handlesTrailingSlash() {
        let locator = ClaudeLocator(loginPath: { "/a/" }, isExecutable: { $0 == "/a/claude" })
        #expect(locator.locate() == .found(path: "/a/claude", searchPath: "/a/"))
    }
}
