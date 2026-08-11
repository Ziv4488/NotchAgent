//
//  ShellShim.swift
//  NotchAgent
//
//  岛塞进用户 shell 的那两样东西：`claude` 包装脚本，和让它赢过 rc 文件的 ZDOTDIR。
//

import Foundation

/// 把 Claude Code 的 hook 接到岛上，靠的是一个叫 `claude` 的包装脚本
/// 抢在真正的 `claude` 前面被找到，透明地补上 `--settings`。
///
/// **光把 bin 目录放进 PATH 最前面是不够的**，这是 08-08 shell-first 之后
/// hook 通道整条静默断掉的原因（08-11 才发现，因为在那之前岛用一个假的
/// 「运行中」状态顶着，看不出来）。岛起的是 `$SHELL -l`，登录 shell 会：
///
/// 1. 跑 `/etc/zprofile` 里的 `path_helper` —— 它按 `/etc/paths` **重建** PATH，
///    再把原有条目接在后面。我们放在最前的目录当场被推到末尾。
/// 2. 跑用户的 `~/.zshrc` —— 里面通常还有 `export PATH="$HOME/.local/bin:$PATH"`
///    之类的前置。真身就装在那种目录里。
///
/// 实测结果是岛里 `command -v claude` 指向 `~/.local/bin/claude`，包装脚本
/// 一次都没被走到。**修法只能是在用户的 rc 跑完之后再前置**，而 zsh 里
/// 唯一干净的切入点是 `ZDOTDIR`：把它指到岛自己的目录，四个 rc 各自先原样
/// 跑一遍用户那一份，再补前置。VS Code 和 iTerm 的 shell 集成用的是同一个机制。
///
/// 非 zsh 的 shell 没有对等的切入点，维持「只前置 PATH」的老办法 ——
/// 用户没在 rc 里前置过同名 `claude` 的话照样成立。
enum ShellShim {
    /// 写包装脚本和 ZDOTDIR 那一套。任何一步失败都抛，由调用方决定怎么降级。
    static func install(binDir: URL, zdotDir: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: binDir, withIntermediateDirectories: true)
        let wrapperURL = binDir.appending(path: "claude")
        try wrapperScript.write(to: wrapperURL, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperURL.path)

        try manager.createDirectory(at: zdotDir, withIntermediateDirectories: true)
        for (name, contents) in zshFiles(binDir: binDir) {
            try contents.write(to: zdotDir.appending(path: name), atomically: true, encoding: .utf8)
        }
    }

    /// 这个 shell 认不认 `ZDOTDIR`。只有 zsh 认。
    static func usesZDotDir(shell: String) -> Bool {
        (shell as NSString).lastPathComponent == "zsh"
    }

    // MARK: - 包装脚本

    /// 自己把自己的目录从 PATH 里摘掉再 exec 真正的 `claude`，所以不会递归。
    ///
    /// `NOTCH_SETTINGS` 没有时原样放行：用户在岛外面、或者在岛里的子 shell 里
    /// 手动清了环境变量时，`claude` 该怎么跑还怎么跑。
    static let wrapperScript = """
    #!/bin/sh
    # NotchAgent: transparently forward Claude Code hooks to the island.
    _d="$(cd "$(dirname "$0")" && pwd)"
    _p=""; _s="$IFS"; IFS=:
    for _x in $PATH; do [ "$_x" != "$_d" ] && _p="${_p:+$_p:}$_x"; done
    IFS="$_s"
    if [ -n "$NOTCH_SETTINGS" ]; then
      exec env PATH="$_p" claude --settings "$NOTCH_SETTINGS" "$@"
    else
      exec env PATH="$_p" claude "$@"
    fi
    """

    // MARK: - ZDOTDIR 那一套

    /// 四个 rc 加一个 logout，文件名 → 内容。
    ///
    /// **顺序和 zsh 默认的一模一样**：`.zshenv` → `.zprofile` → `.zshrc` → `.zlogin`。
    /// 每一个都先原样跑用户那一份，用户的 shell 该是什么样还是什么样。
    ///
    /// 前置放在 `.zshrc` 和 `.zlogin` 两处：`.zshrc` 是绝大多数人改 PATH 的地方，
    /// 而 `.zlogin` 在它之后 —— 有人把 PATH 写在那儿的话，最后一句还得是我们的。
    /// 前置本身是幂等的（已经在最前面就什么都不做）。
    static func zshFiles(binDir: URL) -> [String: String] {
        [
            ".zshenv": prelude + forward(".zshenv"),
            ".zprofile": prelude + forward(".zprofile"),
            ".zshrc": prelude + forward(".zshrc") + prepend(binDir: binDir),
            ".zlogin": prelude + forward(".zlogin") + prepend(binDir: binDir),
            ".zlogout": prelude + forward(".zlogout"),
        ]
    }

    private static let prelude = """
    # NotchAgent 自动生成，每次启动都会覆盖，别在这里改东西。
    # 岛把 ZDOTDIR 指到本目录，好在用户的 rc 跑完之后再前置 PATH（见 ShellShim）。
    NOTCH_USER_ZDOTDIR="${NOTCH_USER_ZDOTDIR:-$HOME}"

    """

    private static func forward(_ file: String) -> String {
        """
        if [ -f "$NOTCH_USER_ZDOTDIR/\(file)" ]; then
          . "$NOTCH_USER_ZDOTDIR/\(file)"
        fi

        """
    }

    /// 用户的 rc 刚跑完，PATH 现在是他说了算的样子 —— 前置必须发生在**这之后**。
    ///
    /// **先摘掉旧的再放到最前，不是直接往前面接。** 岛里再开一层登录 shell 时，
    /// `path_helper` 会把已经在 PATH 里的那份挪到末尾；只往前接的话 PATH 里
    /// 就留着两份同一个目录。摘干净再前置，开几层都只有一份。
    ///
    /// 用 zsh 的 `path` 数组而不是拿 `:` 去切字符串：zsh 默认**不对未加引号的
    /// 参数做分词**，`for x in $PATH` 拿到的是一整条，不是一项一项。
    /// 模式里的 `"$NOTCH_BIN"` 加引号是为了让它按字面比，别被路径里的
    /// `[` `*` 当成通配符。
    private static func prepend(binDir: URL) -> String {
        """
        NOTCH_BIN=\(quoted(binDir.path))
        path=("$NOTCH_BIN" ${path:#"$NOTCH_BIN"})
        export PATH
        unset NOTCH_BIN
        """
    }

    /// 单引号包起来，里面的单引号按 `'\\''` 拆开重接。
    /// 路径里有空格是常态（`Application Support`），有单引号也不是不可能。
    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
