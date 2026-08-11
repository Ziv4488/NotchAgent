#!/bin/bash
# 冒烟：起一个真实的 claude，断言 hook 事件真的抵达了正在跑的 NotchAgent。
#
# 单元测试用假的转发端和假的 payload 把每一段都验过了，但整条链路上
# 有三个只有真机才成立的假设：
#   1. `claude --settings` 认我们生成的那份文件
#   2. hook 命令继承得到我们注入的 NOTCH_TAB
#   3. macOS 的 nc 真的能把字节送进 socket（这条已经骗过我们一次 ——
#      加了 `-N` 之后 nc 秒退但一个字节都没发出去，只看耗时是发现不了的）
#
# 用法：./scripts/smoke.sh   （会自己构建并启动 app）

set -uo pipefail
cd "$(dirname "$0")/.."

SUPPORT="$HOME/Library/Application Support/NotchAgent"
SETTINGS="$SUPPORT/island-hooks.json"
SOCKET="$SUPPORT/hooks.sock"
TAB=$(uuidgen)

fail() { echo "❌ $1"; exit 1; }

echo "==> 构建"
xcodebuild -project NotchAgent/NotchAgent.xcodeproj -scheme NotchAgent \
  -configuration Debug build >/dev/null 2>&1 || fail "构建失败"

echo "==> 启动 app"
pkill -f "NotchAgent.app/Contents/MacOS/NotchAgent" 2>/dev/null
sleep 1
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/NotchAgent-*/Build/Products/Debug/NotchAgent.app 2>/dev/null | head -1)
[ -n "$APP" ] || fail "找不到构建产物"
open "$APP" || fail "起不来"
sleep 3

[ -S "$SOCKET" ] || fail "socket 没建出来：$SOCKET"
[ -f "$SETTINGS" ] || fail "hooks 设置没生成：$SETTINGS"
echo "    socket ✓  settings ✓"

# 设置文件里只能有 hooks —— 多一个键就会顶掉用户 ~/.claude/settings.json 里的同名设置。
KEYS=$(python3 -c "import json;print(','.join(sorted(json.load(open('$SETTINGS')))))")
[ "$KEYS" = "hooks" ] || fail "设置文件里除了 hooks 还有别的键：$KEYS"

SINCE=$(date +"%Y-%m-%d %H:%M:%S")

echo "==> 跑一个真实的 claude 任务"
# CLAUDE_CODE_CHILD_SESSION：从一个 Claude Code 会话里跑这个脚本时会带着它，
# 那会关掉 transcript 保存。清掉，让这次冒烟和用户平时的用法一致。
env -u CLAUDE_CODE_CHILD_SESSION NOTCH_TAB="$TAB" \
  claude --settings "$SETTINGS" -p "只回答两个字：收到" \
  --output-format text >/dev/null 2>&1 || fail "claude 跑失败"

sleep 2

echo "==> 检查事件是否抵达"
# `--info` 不能省：Logger.info 的消息默认不进 log show 的结果，少了它这里永远是空的。
EVENTS=$(/usr/bin/log show --start "$SINCE" --info \
  --predicate 'subsystem == "com.notchagent"' --style compact 2>/dev/null \
  | grep -o "hook [A-Za-z]* tab=[0-9a-fA-F-]*")

echo "$EVENTS" | sed 's/^/    /'

echo "$EVENTS" | grep -q "hook SessionStart" || fail "没收到 SessionStart"
echo "$EVENTS" | grep -q "hook Stop"         || fail "没收到 Stop"
echo "$EVENTS" | grep -q "tab=$TAB"          || fail "事件没带上 NOTCH_TAB（tab 绑定会失效）"

# ---------------------------------------------------------------------------
# 上面那一段**绕开了 shell**：它自己把 --settings 拼在命令行上。
# 岛里不是这么跑的 —— 岛开一个登录 shell，用户敲 `claude`，靠 PATH 找到包装脚本。
# 08-08 到 08-11 之间 hook 通道整条断了三天而这个脚本一直是绿的，就是因为
# 少了下面这一段：真身和包装脚本谁被找到，只有走一遍 shell 才知道。
# ---------------------------------------------------------------------------

echo "==> 走一遍 shell（岛里真正的路径）"
ZDOTDIR_ISLAND="$SUPPORT/zdotdir"
BIN_ISLAND="$SUPPORT/bin"
[ -x "$BIN_ISLAND/claude" ] || fail "包装脚本没生成：$BIN_ISLAND/claude"
[ -f "$ZDOTDIR_ISLAND/.zshrc" ] || fail "ZDOTDIR 那一套没生成：$ZDOTDIR_ISLAND"

# 和 CLISession.environment() 注入的一模一样：PATH 前置 + ZDOTDIR 改指 + 用户原来那个。
SHELL_ENV=(
  "PATH=$BIN_ISLAND:$PATH"
  "ZDOTDIR=$ZDOTDIR_ISLAND"
  "NOTCH_USER_ZDOTDIR=${ZDOTDIR:-$HOME}"
  "NOTCH_SETTINGS=$SETTINGS"
  "NOTCH_TAB=$TAB"
)

RESOLVED=$(env "${SHELL_ENV[@]}" /bin/zsh -l -i -c 'command -v claude' 2>/dev/null | tail -1)
[ "$RESOLVED" = "$BIN_ISLAND/claude" ] || \
  fail "岛里的 claude 不是包装脚本，是 $RESOLVED —— hook 一条都不会发（见 ShellShim）"
echo "    command -v claude → 包装脚本 ✓"

SINCE_SHELL=$(date +"%Y-%m-%d %H:%M:%S")
env -u CLAUDE_CODE_CHILD_SESSION "${SHELL_ENV[@]}" \
  /bin/zsh -l -i -c 'claude -p "只回答两个字：收到" --output-format text' \
  >/dev/null 2>&1 || fail "经由 shell 的 claude 跑失败"

sleep 2
SHELL_EVENTS=$(/usr/bin/log show --start "$SINCE_SHELL" --info \
  --predicate 'subsystem == "com.notchagent"' --style compact 2>/dev/null \
  | grep -o "hook [A-Za-z]* tab=[0-9a-fA-F-]*")
echo "$SHELL_EVENTS" | sed 's/^/    /'
echo "$SHELL_EVENTS" | grep -q "hook Stop" || \
  fail "经由 shell 跑的 claude 没发出 hook —— 包装脚本被绕过了"

echo "✅ 冒烟通过：直连和经由 shell 两条路上，hook 都带着正确的 tab id 抵达"
