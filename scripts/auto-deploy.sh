#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p logs data/audio models

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

# Old background jobs are not allowed to hold the deploy lock or consume the CPU
# while a newer webhook is trying to publish the frontend.
pkill -f "$PROJECT_DIR/scripts/setup-kokoro-english.sh" >/dev/null 2>&1 || true
pkill -f 'scripts/build-voice-previews.py' >/dev/null 2>&1 || true
pkill -f 'scripts/setup-melo.sh' >/dev/null 2>&1 || true
bash "$PROJECT_DIR/scripts/stop-melo.sh" >/dev/null 2>&1 || true
echo '[2/5] 已清理旧 English / preview / Melo worker'

# IMPORTANT DEPLOY RULE:
#   git pull success != process updated != live frontend updated.
# On an existing installation the .venv is already available, so first replace
# the process that owns port 8005 and verify the *actual* latest frontend. Heavy
# model/dependency/selfchecks happen afterwards in the background.
FAST_OK=0
if [ -x "$PROJECT_DIR/.venv/bin/python" ]; then
  echo '[3/5] 立即强制替换旧端口进程，并上线刚拉取的前端'
  if bash "$PROJECT_DIR/scripts/restart.sh"; then
    FAST_OK=1
    echo '[3/5] [OK] 最新前端已由新进程真实提供'
  else
    echo '[3/5] 快速切换失败，将交给完整部署 worker 修复依赖后再次启动'
  fi
else
  echo '[3/5] 首次部署尚无 .venv，跳过快速切换，由完整 worker 创建环境'
fi

# Full verification stays asynchronous so model download/self-tests never make
# BaoTa wait several minutes. It may restart the same latest commit once more after
# dependency/model verification, which is intentional.
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
echo "[4/5] 完整部署 worker=${BOOT_PID} 已在后台启动"

if [ "$FAST_OK" -eq 1 ]; then
  echo "[5/5] [OK] 部署成功：代码、进程、线上前端三层均已切到 commit=${CURRENT_COMMIT}"
  echo '[Project5] 后台 worker 会继续完成模型/依赖/真实 TTS 自检。'
  exit 0
fi

# First deploy or a dependency-changing deploy may need the background worker to
# repair the runtime before the process can start. Give it a short truthful window;
# never report success while an old frontend is still the one actually running.
echo '[5/5] 等待完整 worker 把最新版前端真正启动（最多 90 秒）'
for _ in {1..90}; do
  PAGE="$(curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
  JS="$(curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/static/preview-admin.js?_=${CURRENT_COMMIT}" 2>/dev/null || true)"
  if printf '%s' "$PAGE" | grep -q 'Kokoro 本地试听' \
    && printf '%s' "$PAGE" | grep -q 'Edge 在线试听' \
    && printf '%s' "$JS" | grep -q '这个音色的备注' \
    && printf '%s' "$JS" | grep -q '手动补齐全部音色'; then
    echo "[5/5] [OK] 完整 worker 已把最新版前端真实上线 commit=${CURRENT_COMMIT}"
    exit 0
  fi
  sleep 1
done

echo '[5/5] [ERROR] 最新前端 90 秒内仍未真实上线；后台 worker 继续运行，但本次不能标记成功。'
echo '[Project5] 最近部署日志：'
tail -n 120 "$LOG_FILE" || true
exit 1
