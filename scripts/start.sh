#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p logs data/audio

if [ ! -f .env ]; then
  echo "[Project5] .env 不存在，请先运行 bash scripts/auto-deploy.sh"
  exit 1
fi
if [ ! -x .venv/bin/python ]; then
  echo "[Project5] .venv 不存在，请先运行 bash scripts/auto-deploy.sh"
  exit 1
fi

set -a
source .env
set +a
PORT="${PROJECT5_PORT:-8005}"
PID_FILE="logs/project5.pid"

start_melo_if_installed() {
  if [ -x "$PROJECT_DIR/.venv-melo/bin/python" ] && [ -f "$PROJECT_DIR/.runtime/MeloTTS/melo/api.py" ]; then
    nohup bash "$PROJECT_DIR/scripts/start-melo.sh" >> "$PROJECT_DIR/logs/melo-startup.log" 2>&1 < /dev/null &
  fi
}

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "[Project5] 已在运行 PID=$(cat "$PID_FILE")"
  start_melo_if_installed
  exit 0
fi

nohup .venv/bin/python -m uvicorn app.entry:app \
  --host 127.0.0.1 \
  --port "$PORT" \
  --workers 1 \
  >> logs/app.log 2>&1 &
PID=$!
echo "$PID" > "$PID_FILE"
sleep 2
if ! kill -0 "$PID" 2>/dev/null; then
  echo "[Project5] 启动失败，最近日志："
  tail -n 80 logs/app.log || true
  exit 1
fi
start_melo_if_installed
echo "[Project5] 启动成功 http://127.0.0.1:${PORT} PID=${PID}"
