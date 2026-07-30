#!/bin/bash
# 探针 A —— 验证 hooks 能否通过 --settings 注入，以及与用户设置的合并语义。
#
# 回答三个问题：
#   1. PostToolUse / Stop 等 hook 是否触发，payload 里有没有 session_id
#   2. --settings 是与 ~/.claude/settings.json 合并，还是整体覆盖
#   3. 该文件里定义的键能否覆盖用户设置里的同名键
#
# 判定方法：用户设置里有 model=opus。若注入 hooks-only 的设置后模型仍是 opus，
# 说明是合并；再用一份把 model 改成 haiku 的设置，若模型变成 haiku，说明 CLI
# 侧的设置对它定义的键有更高优先级。两者同时成立 = 干净的合并 + CLI 优先。
#
# 本脚本只读用户配置，不修改。

set -uo pipefail

WORK=/tmp/spike-hooks
LOG="$WORK/events.jsonl"
rm -rf "$WORK"; mkdir -p "$WORK"

PROMPT='用 Read 工具读取 /etc/hosts，然后只回答它的第一行内容，不要解释。'

# ---- 只含 hooks 的设置 ----
cat > "$WORK/hooks-only.json" <<EOF
{
  "hooks": {
    "SessionStart":   [{ "hooks": [{ "type": "command", "command": "{ cat; echo; } >> $LOG" }] }],
    "PreToolUse":     [{ "matcher": "*", "hooks": [{ "type": "command", "command": "{ cat; echo; } >> $LOG" }] }],
    "PostToolUse":    [{ "matcher": "*", "hooks": [{ "type": "command", "command": "{ cat; echo; } >> $LOG" }] }],
    "Notification":   [{ "hooks": [{ "type": "command", "command": "{ cat; echo; } >> $LOG" }] }],
    "Stop":           [{ "hooks": [{ "type": "command", "command": "{ cat; echo; } >> $LOG" }] }]
  }
}
EOF

# ---- 含 hooks 且故意覆盖 model 的设置 ----
sed 's/^{/{\n  "model": "haiku",/' "$WORK/hooks-only.json" > "$WORK/hooks-and-model.json"

run() { # run <settings-or-empty> <outfile>
  local s=$1 out=$2
  if [ -z "$s" ]; then
    claude -p "$PROMPT" --allowedTools Read --output-format json > "$out" 2>"$out.err"
  else
    claude --settings "$s" -p "$PROMPT" --allowedTools Read --output-format json > "$out" 2>"$out.err"
  fi
}

model_of() { python3 - "$1" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception as e: print(f"(解析失败: {e})"); sys.exit()
for k in ("model","modelUsage","usage"):
    if k in d: print(k,"=",json.dumps(d[k],ensure_ascii=False)[:200])
PY
}

echo "===== 1/3 基线：不带 --settings ====="
run "" "$WORK/base.json"; model_of "$WORK/base.json"

echo
echo "===== 2/3 注入 hooks-only ====="
: > "$LOG"
run "$WORK/hooks-only.json" "$WORK/hooked.json"; model_of "$WORK/hooked.json"
echo "--- 收到的 hook 事件 ---"
python3 - "$LOG" <<'PY'
import json,sys
seen=[]
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except Exception: print("  (非 JSON 行)", line[:80]); continue
    seen.append((d.get("hook_event_name"), d.get("session_id"), d.get("tool_name"), sorted(d.keys())))
if not seen: print("  ⚠️ 没有收到任何事件"); raise SystemExit
for ev,sid,tool,keys in seen:
    print(f"  {ev:<14} session_id={'有' if sid else '缺失'} tool={tool}")
print("\n  首个事件的全部字段：")
print("   ", seen[0][3])
PY

echo
echo "===== 3/3 注入 hooks + model=haiku（测 CLI 侧能否覆盖用户设置）====="
run "$WORK/hooks-and-model.json" "$WORK/override.json"; model_of "$WORK/override.json"

echo
echo "===== 4/4 项目级 hooks 会不会被顶掉 ====="
# 在临时目录里放一份项目级 settings，看它的 hook 与注入的 hook 是否同时触发。
PROJ="$WORK/proj"; mkdir -p "$PROJ/.claude"
PROJLOG="$PROJ/project-hook.jsonl"; ISLANDLOG="$PROJ/island-hook.jsonl"
cat > "$PROJ/.claude/settings.json" <<EOF
{ "hooks": { "PostToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "{ cat; echo; } >> $PROJLOG" }] }] } }
EOF
cat > "$PROJ/island.json" <<EOF
{ "hooks": {
    "PostToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "{ cat; echo; } >> $ISLANDLOG" }] }],
    "Stop":        [{ "hooks": [{ "type": "command", "command": "{ cat; echo; } >> $ISLANDLOG" }] }]
} }
EOF
( cd "$PROJ" && claude --settings "$PROJ/island.json" -p "$PROMPT" \
    --allowedTools Read --output-format json > "$PROJ/out.json" 2>"$PROJ/out.err" </dev/null )
echo "  项目级 hook 事件数: $(grep -c . "$PROJLOG" 2>/dev/null || echo 0)   （0 = 被顶掉）"
echo "  岛的 hook 事件数:   $(grep -c . "$ISLANDLOG" 2>/dev/null || echo 0)"

echo
echo "===== 产物 ====="
ls -la "$WORK"
