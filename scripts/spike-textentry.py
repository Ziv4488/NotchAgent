#!/usr/bin/env python3
"""探针 —— 选单里的「Type something.」被选中之后，屏幕变成什么样。

对应用户报的两件事：
  1. 在岛上点了那一项就卡住了 —— 收起态没有键盘焦点，没法打字。
  2. 之后再点别的选项，数字被打进了那个输入框（屏幕上看到 "55534"）。

要修得先知道「它现在是输入框，不是选单」这件事在屏幕上有没有痕迹 ——
页脚那行会不会变。变的话，解析器就认得出来，岛也就知道该展开而不是继续摆选项。

用法：spike-textentry.py
"""

import fcntl
import json
import os
import pty
import struct
import select
import signal
import sys
import re
import termios
import time

WORK = "/tmp/spike-textentry"
CWD = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROMPT = "用 AskUserQuestion 工具问我一个问题：晚饭吃什么，给三个选项。不要做别的事。"

os.makedirs(WORK, exist_ok=True)

pid, fd = os.forkpty()
if pid == 0:
    os.chdir(CWD)
    os.environ["TERM"] = "xterm-256color"
    os.execvp("claude", ["claude"])

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))

start = time.time()
buf = b""
sent = False
stage = 0


ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)?|\x1b[=>()][0-9A-B]?")


def plain(text):
    """扒掉 ANSI 控制序列。原始流里空格是用光标定位「画」出来的，只留可读的字。"""
    return ANSI.sub("", text)


def squashed(text):
    return "".join(text.split()).lower()


def dump(label, text):
    path = f"{WORK}/{label}.txt"
    with open(path, "w") as f:
        f.write(text)
    print(f"\n===== {label} =====")
    for line in plain(text).splitlines()[-26:]:
        line = line.rstrip()
        if line:
            print("  " + line)


def drain(seconds):
    """把接下来这几秒的输出读干净，返回攒下的整块屏。"""
    global buf
    deadline = time.time() + seconds
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.3)
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
    return buf.decode("utf-8", "replace")


while stage < 4:
    now = time.time() - start
    if now > 180:
        print("超时")
        break

    text = drain(0.4)

    if not sent and now > 14:
        os.write(fd, PROMPT.encode())
        time.sleep(1.0)
        os.write(fd, b"\r")
        sent = True
        print(f"[{now:5.1f}] 已发指令")
        continue

    if not sent:
        continue

    flat = squashed(plain(text[-6000:]))

    if stage == 0 and "esctocancel" in flat:
        time.sleep(2.0)
        dump("1-选单", text[-6000:])
        # 找「Type something.」是第几项。
        found = re.search(r"(\d+)\.\s*Type something", plain(text[-8000:]))
        number = found.group(1) if found else None
        print(f"[{now:5.1f}] Type something 是第 {number} 项")
        if number is None:
            break
        buf = b""
        os.write(fd, number.encode())
        stage = 1
        time.sleep(3.0)
        continue

    if stage == 1:
        text = drain(2.0)
        dump("2-选中输入项之后", text[-6000:])
        print("\n  页脚里有没有这些字：")
        flat2 = squashed(plain(text[-4000:]))
        for needle in ("esctocancel", "entertoselect", "tonavigate",
                       "entertosubmit", "esctogoback", "typesomething"):
            print(f"    {needle:16} {'在' if needle in flat2 else '不在'}")
        buf = b""
        os.write(fd, "火锅".encode())
        stage = 2
        time.sleep(2.0)
        continue

    if stage == 2:
        text = drain(2.0)
        dump("3-打了两个字之后", text[-6000:])
        buf = b""
        # 再打一个数字，看它是被当成打字还是被当成选项。
        os.write(fd, b"3")
        stage = 3
        time.sleep(2.0)
        continue

    if stage == 3:
        text = drain(2.0)
        dump("4-又打了一个数字 3", text[-6000:])
        stage = 4

os.kill(pid, signal.SIGKILL)
os.waitpid(pid, 0)
print(f"\n完整输出在 {WORK}/")
