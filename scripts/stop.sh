#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
PID_FILE="logs/project5.pid"

PORT=8005
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
  PORT="${PROJECT5_PORT:-8005}"
fi

PIDS=()
add_pid() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  [ "$pid" -ne "$$" ] || return 0
  for known in "${PIDS[@]:-}"; do [ "$known" = "$pid" ] && return 0; done
  PIDS+=("$pid")
}

# 1) PID file from the current launcher.
if [ -f "$PID_FILE" ]; then
  add_pid "$(cat "$PID_FILE" 2>/dev/null || true)"
fi

# 2) Catch old launch styles too. Older Project5 revisions used different app
# module names, so never limit cleanup to only `app.entry:app`.
while IFS= read -r line; do
  pid="${line%% *}"
  args="${line#* }"
  if [[ "$args" == *"uvicorn"* ]] && [[ "$args" == *"--port $PORT"* ]]; then
    add_pid "$pid"
  fi
done < <(ps -eo pid=,args= | sed 's/^ *//')

# 3) Most important: the port is the source of truth. If an unknown/stale process
# is still LISTENing on Project5's dedicated port, it must be replaced.
if command -v fuser >/dev/null 2>&1; then
  for pid in $(fuser -n tcp "$PORT" 2>/dev/null || true); do add_pid "$pid"; done
fi
if command -v lsof >/dev/null 2>&1; then
  while IFS= read -r pid; do add_pid "$pid"; done < <(lsof -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true)
fi
if command -v ss >/dev/null 2>&1; then
  while IFS= read -r pid; do add_pid "$pid"; done < <(
    ss -ltnp 2>/dev/null | awk -v port=":$PORT" '$1=="LISTEN" && $4 ~ port"$" {print $NF}' \
      | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true
  )
fi

if [ "${#PIDS[@]}" -gt 0 ]; then
  echo "[Project5] 强制停止占用 ${PORT} 的旧进程: ${PIDS[*]}"
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  for _ in {1..30}; do
    alive=0
    for pid in "${PIDS[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1 || true; done
    [ "$alive" -eq 0 ] && break
    sleep 0.2
  done
  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
  done
else
  echo "[Project5] ${PORT} 未发现旧 API 进程"
fi
rm -f "$PID_FILE"

# Verify the dedicated port is really free. This prevents the classic failure:
# git pull succeeded, restart looked successful, but an old listener kept serving
# the previous frontend.
LISTENER_LEFT=0
if command -v fuser >/dev/null 2>&1 && fuser -n tcp "$PORT" >/dev/null 2>&1; then LISTENER_LEFT=1; fi
if [ "$LISTENER_LEFT" -eq 0 ] && command -v lsof >/dev/null 2>&1 && lsof -t -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then LISTENER_LEFT=1; fi
if [ "$LISTENER_LEFT" -eq 1 ]; then
  echo "[Project5][ERROR] 端口 ${PORT} 仍被进程占用，拒绝假装重启成功"
  exit 1
fi

echo "[Project5] 已确认端口 ${PORT} 释放"
