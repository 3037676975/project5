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
# shellcheck disable=SC1091
source .env
set +a
PORT="${PROJECT5_PORT:-8005}"
PID_FILE="logs/project5.pid"

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "[Project5] 已在运行 PID=$(cat "$PID_FILE")；start.sh 不会假装这是新版本，请使用 restart.sh"
  exit 2
fi

nohup .venv/bin/python -m uvicorn app.entry:app \
  --host 127.0.0.1 \
  --port "$PORT" \
  --workers 1 \
  >> logs/app.log 2>&1 &
PID=$!
echo "$PID" > "$PID_FILE"

for _ in {1..60}; do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "[Project5] 启动进程已退出，最近日志："
    tail -n 120 logs/app.log || true
    rm -f "$PID_FILE"
    exit 1
  fi

  HEALTH="$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)"
  if printf '%s' "$HEALTH" | grep -q '"console":"dual-engine-v2"'; then
    PAGE_FILE="$(mktemp)"
    if curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/" -o "$PAGE_FILE" \
      && grep -q 'Kokoro 本地试听' "$PAGE_FILE" \
      && grep -q 'Edge 在线试听' "$PAGE_FILE"; then
      rm -f "$PAGE_FILE"
      echo "[Project5] 新版 API 已启动 http://127.0.0.1:${PORT} PID=${PID}"
      echo "[Project5] 控制台校验通过：Kokoro 本地试听 + Edge 在线试听"
      exit 0
    fi
    rm -f "$PAGE_FILE"
  fi
  sleep 1
done

echo "[Project5] 进程存在，但 60 秒内没有提供 dual-engine-v2 新控制台"
echo "[Project5] /health: $(curl -s --max-time 3 "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)"
tail -n 160 logs/app.log || true
exit 1
