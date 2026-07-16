#!/bin/sh
# installed by TokenMeter
# managed by TokenMeter; reinstalling or updating the app overwrites this file.
# TOKENMETER_INTEGRATION_VERSION=2
#
# 用法：tokenmeter-agent-hook.sh <agentKind> <event>
#   agentKind: claudeCode | codex     event: start | heartbeat | blocked | stop
# stdin 是 agent 的 hook JSON（含 session_id / cwd）。
# $PPID 即 agent 进程（生态同款取法，supacode 亦如此）——start 事件靠它
# 把同进程的旧会话置 ended（/resume 切会话场景）。
# 防御式：任何失败都 exit 0、绝不阻塞 agent；上报是后台 fire-and-forget。

set -u

agent="${1:-}"
event="${2:-}"
[ -n "$agent" ] && [ -n "$event" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(mktemp "${TMPDIR:-/tmp}/tokenmeter-hook.XXXXXX")" || exit 0
cat >"$input" 2>/dev/null || true

# 临时文件由后台 python 负责删除——父 shell 立即退出，trap 靠不住。
TOKENMETER_AGENT="$agent" TOKENMETER_EVENT="$event" TOKENMETER_INPUT="$input" TOKENMETER_OWNER_PID="$PPID" python3 - <<'PY' >/dev/null 2>&1 &
import json, os, socket

agent = os.environ.get("TOKENMETER_AGENT", "")
event = os.environ.get("TOKENMETER_EVENT", "")
input_path = os.environ.get("TOKENMETER_INPUT", "")

payload = {}
try:
    with open(input_path, encoding="utf-8") as handle:
        text = handle.read()
    if text.strip():
        payload = json.loads(text)
except Exception:
    payload = {}
finally:
    try:
        os.unlink(input_path)
    except Exception:
        pass

session_id = str(payload.get("session_id") or payload.get("sessionId") or "")
cwd = str(payload.get("cwd") or "")
if not session_id:
    raise SystemExit(0)

request = {
    "id": f"hook-{os.getpid()}",
    "method": "agent.sessionEvent",
    "params": {
        "agent": agent,
        "event": event,
        "sessionId": session_id,
        "cwd": cwd,
        "ownerPid": os.environ.get("TOKENMETER_OWNER_PID", ""),
    },
}

try:
    with socket.create_connection(("127.0.0.1", 47731), timeout=2) as conn:
        conn.sendall((json.dumps(request) + "\n").encode("utf-8"))
        conn.recv(4096)
except Exception:
    pass
PY

exit 0
