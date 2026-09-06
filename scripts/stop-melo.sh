#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
PORT="${MELO_PORT:-8016}"
PID_FILE="$PROJECT_DIR/logs/melo.pid"
PIDS=()

if [ -f "$PID_FILE" ]; then
  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ "$PID" =~ ^[0-9]+$ ]] && kill -0 "$PID" 2>/dev/null; then PIDS+=("$PID"); fi
fi
while IFS= read -r line; do
  pid="${line%% *}"
  args="${line#* }"
  if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$args" == *"scripts/melo_worker.py"* ]] && [[ "$args" == *"--port $PORT"* ]]; then
    found=0
    for known in "${PIDS[@]:-}"; do [ "$known" = "$pid" ] && found=1 && break; done
    [ "$found" -eq 1 ] || PIDS+=("$pid")
  fi
done < <(ps -eo pid=,args= | sed 's/^ *//')

for pid in "${PIDS[@]:-}"; do
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
done
for _ in {1..20}; do
  alive=0
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1; done
  [ "$alive" -eq 0 ] && break
  sleep 0.25
done
for pid in "${PIDS[@]:-}"; do
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
done
rm -f "$PID_FILE"
echo '[MeloTTS] stopped'
