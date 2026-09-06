#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
PID_FILE="logs/project5.pid"
if [ ! -f "$PID_FILE" ]; then
  echo "[Project5] 没有 PID 文件，服务可能未运行"
  exit 0
fi
PID="$(cat "$PID_FILE")"
if kill -0 "$PID" 2>/dev/null; then
  kill "$PID"
  for _ in {1..15}; do
    kill -0 "$PID" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$PID" 2>/dev/null; then
    kill -9 "$PID" || true
  fi
fi
rm -f "$PID_FILE"
echo "[Project5] 已停止"
