#!/usr/bin/env python3
"""探针 A 补丁 —— 抓一个真实的 Notification hook payload。

spike-hooks.sh 用的是 `claude -p`（非交互），永远不会有权限询问，
所以抓不到 Notification —— 而那正是岛的「等你回话」态唯一的触发源。

这里在真正的伪终端里起一个交互式 claude，让它去写一个 cwd 之外的文件，
Claude Code 会停下来问「允许吗」，Notification hook 随之触发。
拿到事件就立刻杀掉子进程，**不回答那个询问**，什么都不会被真的写出去。
"""

import fcntl
import json
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

WORK = "/tmp/spike-notification"
LOG = f"{WORK}/events.jsonl"
CWD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # 项目根目录（已受信任）
PROMPT = "用 Write 工具在 /tmp/spike-notification/note.txt 写入一行 hi。直接做，不要先解释。"

os.makedirs(WORK, exist_ok=True)
open(LOG, "w").close()

settings = f"{WORK}/hooks.json"
with open(settings, "w") as f:
    json.dump({
        "hooks": {
            name: [{"hooks": [{"type": "command", "command": f"{{ cat; echo; }} >> {LOG}"}]}]
            for name in ("SessionStart", "Notification", "PreToolUse", "Stop")
        }
    }, f)

pid, fd = os.forkpty()
if pid == 0:
    os.chdir(CWD)
    os.environ["TERM"] = "xterm-256color"
    os.execvp("claude", ["claude", "--settings", settings])

# 给足一个真终端的尺寸，否则 Claude Code 的 TUI 会挤成一团。
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

start = time.time()
sent = False
got = False
# 把 TUI 的原始输出录下来 —— 喂进去的指令没被提交时，只有这份录像能说明它当时卡在哪。
screen = open(f"{WORK}/pty.log", "wb")
while time.time() - start < 120:
    ready, _, _ = select.select([fd], [], [], 0.4)
    if ready:
        try:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            screen.write(chunk)
            screen.flush()
        except OSError:
            break

    # 等 TUI 起来再喂指令。TUI 是逐字符收的，整段一次性灌进去会被吞掉开头，
    # 所以分字符写、再单独发回车。
    if not sent and time.time() - start > 8:
        for byte in PROMPT.encode():
            os.write(fd, bytes([byte]))
            time.sleep(0.004)
        time.sleep(0.4)
        os.write(fd, b"\r")
        sent = True

    if sent and any("Notification" in line for line in open(LOG)):
        got = True
        # 让 hook 的写入落盘。
        time.sleep(1.5)
        break

os.kill(pid, signal.SIGKILL)
os.waitpid(pid, 0)

print("抓到 Notification" if got else "⚠️ 超时，没等到 Notification")
for line in open(LOG):
    line = line.strip()
    if not line:
        continue
    event = json.loads(line)
    print("=== " + str(event.get("hook_event_name")))
    print(json.dumps(event, ensure_ascii=False, indent=2))
sys.exit(0 if got else 1)
