//
//  ClaudeLocator.swift
//  NotchAgent
//
//  找到 `claude` 可执行文件（spec 5.1）。
//

import Foundation

/// 定位 `claude` 可执行文件，并顺带拿到用户 shell 的真实 PATH。
///
/// **为什么不能直接 `which claude`**：从 Finder / Dock 启动的 GUI app 拿到的是
/// `launchd` 的 PATH（大致就是 `/usr/bin:/bin:/usr/sbin:/sbin`），
/// 用户装在 `~/.local/bin`、`/opt/homebrew/bin`、nvm 的 node 目录里的 `claude` 一个都看不见。
/// 所以要跑一次登录 shell 把它的 PATH 问出来。
///
/// 这个 PATH 除了找 `claude`，还要原样传给 PTY 里的子进程 ——
/// 否则 `claude` 起来了，它调 `git` / `npm` / `rg` 又全都找不到。
struct ClaudeLocator {
    /// 跑一次登录 shell 取 PATH。抽成闭包是为了能在测试里喂假输出。
    var loginPath: () -> String?
    /// 判断某个路径是不是可执行文件。同样为了可测。
    var isExecutable: (String) -> Bool
    /// 用户在设置里手填的绝对路径，优先级最高。
    var override: String?

    init(override: String? = nil,
         loginPath: @escaping () -> String? = ClaudeLocator.shellPath,
         isExecutable: @escaping (String) -> Bool = ClaudeLocator.defaultIsExecutable) {
        self.override = override
        self.loginPath = loginPath
        self.isExecutable = isExecutable
    }

    enum Result: Equatable {
        case found(path: String, searchPath: String)
        /// PATH 拿到了，但里面没有 `claude` —— 需要用户手填（spec 8 的第一行）。
        case notFound(searchPath: String)
    }

    func locate() -> Result {
        let path = loginPath() ?? Self.fallbackPath
        // 手填的路径也要验一遍：用户可能填了个已经被卸载掉的路径，
        // 那时候宁可退回自动搜索，也不要拿着一个坏路径去 spawn。
        if let override, isExecutable(override) {
            return .found(path: override, searchPath: path)
        }
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = directory.hasSuffix("/") ? "\(directory)claude" : "\(directory)/claude"
            if isExecutable(candidate) {
                return .found(path: candidate, searchPath: path)
            }
        }
        return .notFound(searchPath: path)
    }

    // MARK: - 默认实现

    /// launchd 给 GUI app 的 PATH 太窄，兜底至少把常见的包管理器目录带上。
    static let fallbackPath =
        "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// `$SHELL -ilc 'echo $PATH'`。
    ///
    /// `-i` 不能省：很多人的 PATH 是在 `.zshrc` 里拼的，而 `.zshrc` 只有交互式 shell 才读。
    /// 代价是会把用户 rc 里的输出一起收进来，所以只取**最后一行非空输出**当 PATH。
    static func shellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "echo $PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // 有人的 rc 里会写 `read` 之类的交互动作，那会把我们挂死在启动路径上。
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parsePath(text)
    }

    /// 从 shell 的输出里挑出 PATH：取最后一行含 `/` 的非空行。
    static func parsePath(_ output: String) -> String? {
        let candidate = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && $0.contains("/") }
        guard let candidate, !candidate.isEmpty else { return nil }
        return candidate
    }

    static func defaultIsExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
}
