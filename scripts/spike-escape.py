#!/usr/bin/env python3
"""探针 —— 选单出现后按 Esc 不选，之后还会不会有收尾事件。

对应用户报的 bug：「出选项后，按 esc 不选，琥珀色呼吸灯会一直亮」。

岛现在的逻辑是：选单消失 = 答完了 → 状态交回 `.running`，等 hook 来纠正。
如果 Esc 之后**一个 hook 都不来**，那个 `.running` 就永远挂着，
状态点一直琥珀色慢呼吸 —— 正是用户看到的现象。

两种选单分别测（它们的来路不一样）：
  permission —— 工具权限询问，有 `Notification` hook 打头
  question   —— `AskUserQuestion`，只有 `PreToolUse`，没有 `Notification`

结论（2026-07-31，Claude Code v2.1.220）：**两种都是 Esc 之后零事件。**
顺带纠正一条旧结论：`AskUserQuestion` 是发 `PreToolUse` 的，payload 里带着
完整的问题和选项；它不发的是 `Notification`，所以没有任何事件说「它停下来等你了」。

用法：spike-escape.py permission | question
"""

import fcntl
import json
import os
import pty
import struct
import select
import signal
import sys
import termios
import time

MODE = sys.argv[1] if len(sys.argv) > 1 else "permission"
WORK = f"/tmp/spike-escape-{MODE}"
LOG = f"{WORK}/events.jsonl"
SCREEN = f"{WORK}/screen-after-esc.txt"
CWD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PROMPTS = {
    "permission": "用 Write 工具在 /tmp/spike-escape-permission/note.txt 写入一行 hi。直接做，不要先解释。",
    "question": "用 AskUserQuestion 工具问我一个问题：晚饭吃什么，给三个选项。不要做别的事。",
}
PROMPT = PROMPTS[MODE]

EVENTS = ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
          "Notification", "Stop", "SubagentStop", "SessionEnd", "PreCompact")

os.makedirs(WORK, exist_ok=True)
open(LOG, "w").close()

settings = f"{WORK}/hooks.json"
with open(settings, "w") as f:
    json.dump({
        "hooks": {
            name: [{"hooks": [{
                "type": "command",
                "command": f'{{ echo "@@{name} $(date +%s.%N)"; cat; echo; }} >> {LOG}',
            }]}]
            for name in EVENTS
        }
    }, f)

pid, fd = os.forkpty()
if pid == 0:
    os.chdir(CWD)
    os.environ["TERM"] = "xterm-256color"
    os.execvp("claude", ["claude", "--settings", settings])

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

start = time.time()
buf = b""
sent = False
escaped = False
esc_at = None


def log_text():
    return open(LOG, encoding="utf-8", errors="replace").read()


def squashed(text):
    """原始字节流里空格是被光标定位「画」出来的，压掉所有空白再找。"""
    return "".join(text.split()).lower()


while True:
    now = time.time() - start
    # 按下 Esc 之后再等 25 秒，专门看还会不会来事件。
    if now > 150 or (esc_at and time.time() - esc_at > 25):
        break

    ready, _, _ = select.select([fd], [], [], 0.4)
    if ready:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk

    text = buf.decode("utf-8", "replace")

    # 起来得慢（MCP 要连），太早打字会连回车一起被吃掉 —— 等久一点，
    # 而且回车单独发，别跟正文粘在同一次 write 里当成粘贴。
    if not sent and now > 14:
        os.write(fd, PROMPT.encode())
        time.sleep(1.0)
        os.write(fd, b"\r")
        sent = True
        print(f"[{now:5.1f}] 已发指令（{MODE}）")
        continue

    if not sent or escaped:
        continue

    # 权限询问有 Notification 打头；AskUserQuestion 一个 hook 都不发，
    # 只能认屏幕上那行页脚。
    if MODE == "permission":
        appeared = "@@Notification" in log_text()
    else:
        appeared = "esctocancel" in squashed(text[-6000:])

    if appeared:
        time.sleep(2.0)          # 等选单画完
        mark = len(log_text())   # 记下 Esc 之前的事件量
        os.write(fd, b"\x1b")    # Esc：不选，直接取消
        escaped = True
        esc_at = time.time()
        print(f"[{now:5.1f}] 选单出现了，已按 Esc")
        time.sleep(4.0)
        buf = b""                # 清干净，只看 Esc 之后画的屏
        continue

os.kill(pid, signal.SIGKILL)
os.waitpid(pid, 0)

with open(SCREEN, "w") as f:
    f.write(buf.decode("utf-8", "replace")[-12000:])

raw = log_text()
order = []
for line in raw.splitlines():
    if line.startswith("@@"):
        name, ts = line[2:].split()
        order.append((name, float(ts) - start))

print(f"\n===== 事件顺序（{LOG}）=====")
esc_rel = (esc_at - start) if esc_at else None
for name, at in order:
    tail = "   ← Esc 之后" if esc_rel and at > esc_rel else ""
    print(f"  +{at:6.2f}s  {name}{tail}")
if esc_rel:
    after = [n for n, at in order if at > esc_rel]
    print(f"\n  Esc 按于 +{esc_rel:.2f}s；之后共 {len(after)} 条事件：{after or '（一条都没有）'}")
else:
    print("  选单没等到")

print(f"\n===== Esc 之后的屏幕（压掉空白，看有没有转圈）=====")
tail = squashed(buf.decode('utf-8', 'replace')[-4000:])
for needle in ("esctointerrupt", "esctocancel", "esctoundo"):
    print(f"  {needle:16} {'在' if needle in tail else '不在'}")
print(f"  完整原始输出：{SCREEN}")
