#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
PID_FILE="logs/project5.pid"

PORT=8005
if [ -f .env ]; then
  set -a
  source .env
  set +a
  PORT="${PROJECT5_PORT:-8005}"
fi

PIDS=()
if [ -f "$PID_FILE" ]; then
  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ "$PID" =~ ^[0-9]+$ ]] && kill -0 "$PID" 2>/dev/null; then PIDS+=("$PID"); fi
fi
while IFS= read -r line; do
  pid="${line%% *}"
  args="${line#* }"
  if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$args" == *"uvicorn app.entry:app"* ]] && [[ "$args" == *"--port $PORT"* ]]; then
    seen=0
    for known in "${PIDS[@]:-}"; do [ "$known" = "$pid" ] && seen=1 && break; done
    [ "$seen" -eq 1 ] || PIDS+=("$pid")
  fi
done < <(ps -eo pid=,args= | sed 's/^ *//')

if [ "${#PIDS[@]}" -gt 0 ]; then
  echo "[Project5] 正在停止旧进程: ${PIDS[*]}"
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  for _ in {1..20}; do
    alive=0
    for pid in "${PIDS[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1 || true; done
    [ "$alive" -eq 0 ] && break
    sleep 0.5
  done
  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
  done
fi
rm -f "$PID_FILE"

bash "$PROJECT_DIR/scripts/stop-melo.sh" >/dev/null 2>&1 || true

echo "[Project5] 已停止 Project5 API + MeloTTS runtime"
