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

# Deployment experience rule: code updated != process updated != live UI updated.
# Always release the real Project5 port first, even if a stale PID file says otherwise.
bash "$PROJECT_DIR/scripts/stop.sh"

nohup .venv/bin/python -m uvicorn app.entry:app \
  --host 127.0.0.1 \
  --port "$PORT" \
  --workers 1 \
  >> logs/app.log 2>&1 &
PID=$!
echo "$PID" > "$PID_FILE"

ONLINE=0
for _ in {1..50}; do
  if ! kill -0 "$PID" 2>/dev/null; then break; fi
  PAGE="$(curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
  PREVIEW_JS="$(curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/static/preview-admin.js?_=${CURRENT_COMMIT}" 2>/dev/null || true)"
  LIBRARY_JS="$(curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/static/voice-library.js?_=${CURRENT_COMMIT}" 2>/dev/null || true)"
  VERSION="$(curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/deploy-version?_=${CURRENT_COMMIT}" 2>/dev/null || true)"
  if printf '%s' "$PAGE" | grep -q 'Kokoro 本地试听' \
    && printf '%s' "$PAGE" | grep -q 'Edge 在线试听' \
    && printf '%s' "$PAGE" | grep -q 'preview-admin.js' \
    && printf '%s' "$PREVIEW_JS" | grep -q 'voice-library.js' \
    && printf '%s' "$PREVIEW_JS" | grep -q '一键生成全部试听' \
    && printf '%s' "$LIBRARY_JS" | grep -q '音色库 / 固定试听表' \
    && printf '%s' "$LIBRARY_JS" | grep -q '24小时自动清理' \
    && printf '%s' "$LIBRARY_JS" | grep -q 'Project5 双引擎 API' \
    && printf '%s' "$VERSION" | grep -q "$CURRENT_COMMIT" \
    && printf '%s' "$VERSION" | grep -q 'voice-library-retention-v1'; then
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
echo "[Project5] 已验证：端口新进程 + 当前 commit + 音色库表格 + 批量圆环进度 + 音色备注 + 24h保存开关 + API文档"
