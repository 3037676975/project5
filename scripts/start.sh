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
CURRENT_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
export PROJECT5_COMMIT="$CURRENT_COMMIT"

# Never trust a stale PID file. start.sh itself guarantees the Project5 port is
# free before launching, so it is safe even when called without restart.sh.
bash "$PROJECT_DIR/scripts/stop.sh"

nohup .venv/bin/python -m uvicorn app.entry:app \
  --host 127.0.0.1 \
  --port "$PORT" \
  --workers 1 \
  >> logs/app.log 2>&1 &
PID=$!
echo "$PID" > "$PID_FILE"

# A process existing for 2 seconds is not enough. Verify the actual page, updated
# UI JS, AND the commit reported by the running process.
ONLINE=0
for _ in {1..40}; do
  if ! kill -0 "$PID" 2>/dev/null; then break; fi
  PAGE="$(curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
  JS="$(curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/static/preview-admin.js?_=${CURRENT_COMMIT}" 2>/dev/null || true)"
  VERSION="$(curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/deploy-version?_=${CURRENT_COMMIT}" 2>/dev/null || true)"
  if printf '%s' "$PAGE" | grep -q 'Kokoro 本地试听' \
    && printf '%s' "$PAGE" | grep -q 'Edge 在线试听' \
    && printf '%s' "$PAGE" | grep -q 'preview-admin.js' \
    && printf '%s' "$JS" | grep -q '这个音色的备注' \
    && printf '%s' "$JS" | grep -q '手动补齐全部音色' \
    && printf '%s' "$VERSION" | grep -q "$CURRENT_COMMIT"; then
    ONLINE=1
    break
  fi
  sleep 0.5
done

if [ "$ONLINE" -ne 1 ]; then
  echo "[Project5][ERROR] 新进程没有成功提供当前 commit 的最新版前端，PID=${PID} PORT=${PORT} commit=${CURRENT_COMMIT}"
  tail -n 120 logs/app.log || true
  bash "$PROJECT_DIR/scripts/stop.sh" || true
  exit 1
fi

echo "[Project5] 最新进程已上线 commit=${CURRENT_COMMIT} http://127.0.0.1:${PORT} PID=${PID}"
echo "[Project5] 已验证：端口新进程 + 当前 commit + Kokoro/Edge + 手动固定试听 + 音色备注"
