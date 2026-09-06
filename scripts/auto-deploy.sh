#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p logs data/audio models

# Known-good deployment path restored from commit
# f4a24ef1c52ee29121acf5387ada2e4147383299.
# BaoTa's Git auto-deploy plugin performs `git pull` before this script runs.
# Do NOT rewrite BaoTa/Nginx configuration on every code deployment: that was
# introduced after f4a24ef and is what caused the repeated deployment failures.
printf '%s\n' '=============================================='
printf '%s\n' ' Project5 · Verified Webhook Deploy'
printf '%s\n' '=============================================='

PYTHON_BIN=""
for candidate in python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
    PYTHON_BIN="$candidate"
    break
  fi
done
[ -n "$PYTHON_BIN" ] || { echo '[ERROR] 需要 Python 3.10+'; exit 1; }
CURRENT_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
echo "[1/5] commit=${CURRENT_COMMIT} Python=$($PYTHON_BIN --version)"

set_env_value() {
  local key="$1" value="$2"
  if grep -q "^${key}=" .env 2>/dev/null; then sed -i "s#^${key}=.*#${key}=${value}#" .env
  else printf '%s=%s\n' "$key" "$value" >> .env; fi
}

if [ ! -f .env ]; then
  ADMIN_KEY="admin-p5-$($PYTHON_BIN -c 'import secrets; print(secrets.token_urlsafe(32))')"
  cat > .env <<EOF
PROJECT5_PORT=8005
ADMIN_KEY=${ADMIN_KEY}
MAX_TEXT_LENGTH=5000
EOF
fi
set_env_value KOKORO_THREADS 8
set_env_value KOKORO_ONNX_MODEL "${PROJECT_DIR}/models/kokoro-v1.1-zh.onnx"
set_env_value KOKORO_ONNX_VOICES "${PROJECT_DIR}/models/voices-v1.1-zh.bin"
set_env_value KOKORO_ONNX_CONFIG "${PROJECT_DIR}/models/config.json"
chmod 600 .env
set -a
# shellcheck disable=SC1091
source .env
set +a
PORT="${PROJECT5_PORT:-8005}"

pkill -f "$PROJECT_DIR/scripts/setup-kokoro-english.sh" >/dev/null 2>&1 || true
pkill -f 'scripts/build-voice-previews.py' >/dev/null 2>&1 || true
pkill -f 'scripts/setup-melo.sh' >/dev/null 2>&1 || true
bash "$PROJECT_DIR/scripts/stop-melo.sh" >/dev/null 2>&1 || true
echo '[2/5] 已清理旧 English / preview / Melo worker'

# Experience rule: code updated != process updated != live frontend updated.
FAST_OK=0
if [ -x "$PROJECT_DIR/.venv/bin/python" ]; then
  echo '[3/5] 立即释放 Project5 端口，杀掉旧前端进程并启动当前 commit'
  if bash "$PROJECT_DIR/scripts/restart.sh"; then
    FAST_OK=1
    echo '[3/5] [OK] 新进程已经启动并通过当前前端验证'
  else
    echo '[3/5] 快速切换失败，将交给完整部署 worker 修复依赖后再次启动'
  fi
else
  echo '[3/5] 首次部署尚无 .venv，跳过快速切换，由完整 worker 创建环境'
fi

LOG_FILE="$PROJECT_DIR/logs/bootstrap-runtime.log"
WORKER="$PROJECT_DIR/scripts/repair-runtime-assets.sh"
if command -v setsid >/dev/null 2>&1; then
  nohup setsid bash "$WORKER" >> "$LOG_FILE" 2>&1 < /dev/null &
else
  nohup bash "$WORKER" >> "$LOG_FILE" 2>&1 < /dev/null &
fi
BOOT_PID=$!
disown "$BOOT_PID" 2>/dev/null || true
printf '%s\n' "$BOOT_PID" > "$PROJECT_DIR/logs/deploy-worker.pid"
echo "[4/5] 完整部署 worker=${BOOT_PID} 已在后台启动；不会挡住前端切换"

live_is_current() {
  local page preview_js library_js version
  page="$(curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
  preview_js="$(curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/static/preview-admin.js?_=${CURRENT_COMMIT}" 2>/dev/null || true)"
  library_js="$(curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/static/voice-library.js?_=${CURRENT_COMMIT}" 2>/dev/null || true)"
  version="$(curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/deploy-version?_=${CURRENT_COMMIT}" 2>/dev/null || true)"
  printf '%s' "$page" | grep -q 'Kokoro 本地试听' \
    && printf '%s' "$page" | grep -q 'Edge 在线试听' \
    && printf '%s' "$preview_js" | grep -q 'voice-library.js' \
    && printf '%s' "$preview_js" | grep -q '一键生成全部试听' \
    && printf '%s' "$library_js" | grep -q '音色库 / 固定试听表' \
    && printf '%s' "$library_js" | grep -q '24小时自动清理' \
    && printf '%s' "$library_js" | grep -q 'Project5 双引擎 API' \
    && printf '%s' "$version" | grep -q "$CURRENT_COMMIT" \
    && printf '%s' "$version" | grep -q 'voice-library-retention-v1'
}

if [ "$FAST_OK" -eq 1 ] && live_is_current; then
  echo "[5/5] [OK] 部署成功：代码、端口新进程、线上 commit、新功能四层一致 ${CURRENT_COMMIT}"
  echo '[Project5] 后台 worker 会继续完成模型/依赖/真实 TTS 自检，但不再阻塞前端。'
  exit 0
fi

echo '[5/5] 等待完整 worker 把当前 commit 的最新版前端真正启动（最多 90 秒）'
for _ in {1..90}; do
  if live_is_current; then
    echo "[5/5] [OK] 完整 worker 已把当前 commit 真实上线 ${CURRENT_COMMIT}"
    exit 0
  fi
  sleep 1
done

echo '[5/5] [ERROR] 当前 commit 90 秒内仍未真实上线；后台 worker 继续运行，但本次不能标记成功。'
echo '[Project5] 最近部署日志：'
tail -n 120 "$LOG_FILE" || true
exit 1
