#!/usr/bin/env python3
"""探针 —— 一个回合到底会发出哪些 hook，以及「拒绝」之后还有没有收尾事件。

要回答两个问题，它们各自对应一个已知的界面 bug：

1. **`UserPromptSubmit` 会不会触发、payload 长什么样。**
   岛现在把「回合开始」定在 `SessionStart` 上，可那只是「会话起来了、
   停在提示符前」——于是一个什么都没干的会话，状态点一直琥珀色慢呼吸、
   计时一直往上走，跟真的干活时长毫无关系。真正的回合起点应该是这个 hook。

2. **权限询问被拒绝之后，还会不会有 `Stop`。**
   如果没有，tab 就永远停在「等你回话」，岛再也回不到 idle —— 用户报的
   「一直挂着通知态」。

顺带把 `SubagentStop` / `SessionEnd` / `PreCompact` 也挂上，看看还有什么。

全程在伪终端里跑真的 claude，事件按到达顺序连同相对时刻写进 events.jsonl。
问的那个写文件请求会被**拒绝**，磁盘上不会留下东西。
"""

import fcntl
import json
import os
import pty
import re
import struct
import select
import signal
import sys
import termios
import time

WORK = "/tmp/spike-turn"
LOG = f"{WORK}/events.jsonl"
SCREEN = f"{WORK}/screen.txt"
CWD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROMPT = "用 Write 工具在 /tmp/spike-turn/note.txt 写入一行 hi。直接做，不要先解释。"

EVENTS = ("SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
          "Notification", "Stop", "SubagentStop", "SessionEnd", "PreCompact")

os.makedirs(WORK, exist_ok=True)
open(LOG, "w").close()

settings = f"{WORK}/hooks.json"
with open(settings, "w") as f:
    # 每条事件前面加一行 "<事件名> <到达时刻>"，好还原顺序 ——
    # payload 自己带的 hook_event_name 不保证每种事件都有。
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
denied = False
deny_at = None


def elapsed():
    return time.time() - start


while True:
    now = elapsed()
    # 拒绝之后再等 25 秒，专门看还会不会来 Stop。
    if now > 120 or (deny_at and time.time() - deny_at > 25):
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

    if not sent and now > 6:
        os.write(fd, PROMPT.encode() + b"\r")
        sent = True
        print(f"[{now:5.1f}] 已发指令")
        continue

    # 认「询问出现了」不靠屏幕文字 —— 那是要变的。Notification hook 到了就是到了。
    if sent and not denied and "@@Notification" in open(LOG, errors="replace").read():
        time.sleep(2.0)   # 等选单画完
        with open(SCREEN, "w") as f:
            f.write(text[-12000:])
        os.write(fd, b"2")     # Claude Code 的选单里 2 是「不允许」
        time.sleep(0.3)
        os.write(fd, b"\r")
        denied = True
        deny_at = time.time()
        print(f"[{now:5.1f}] Notification 到了，已选「不允许」，屏幕存到 {SCREEN}")

os.kill(pid, signal.SIGKILL)
os.waitpid(pid, 0)

print(f"\n===== 事件顺序（{LOG}）=====")
order = []
for line in open(LOG, encoding="utf-8", errors="replace"):
    if line.startswith("@@"):
        name, ts = line[2:].split()
        order.append((name, float(ts) - start))
for name, at in order:
    print(f"  +{at:6.2f}s  {name}")

print("\n===== 各事件出现次数 =====")
counts = {}
for name, _ in order:
    counts[name] = counts.get(name, 0) + 1
for name in EVENTS:
    print(f"  {name:18} {counts.get(name, 0)}")

print("\n===== UserPromptSubmit 的 payload =====")
raw = open(LOG, encoding="utf-8", errors="replace").read()
blocks = raw.split("@@")
for block in blocks:
    if block.startswith("UserPromptSubmit"):
        body = block.split("\n", 1)[1].strip()
        try:
            print(json.dumps(json.loads(body), ensure_ascii=False, indent=2)[:1200])
        except Exception:
            print(body[:600])
        break
else:
    print("  （没有触发）")
