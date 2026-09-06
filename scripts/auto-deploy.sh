#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p logs data/audio models

printf '%s\n' '=============================================='
printf '%s\n' ' Project5 · Verified Auto Deploy'
printf '%s\n' '=============================================='

PYTHON_BIN=""
for candidate in python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
    PYTHON_BIN="$candidate"
    break
  fi
done
[ -n "$PYTHON_BIN" ] || { echo '[ERROR] 需要 Python 3.10+'; exit 1; }
echo "[1/4] Python: $($PYTHON_BIN --version)"

set_env_value() {
  local key="$1" value="$2"
  if grep -q "^${key}=" .env 2>/dev/null; then
    sed -i "s#^${key}=.*#${key}=${value}#" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
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

echo '[2/4] 启动部署 worker：修复资产 → 强制替换旧 Uvicorn → 验证新版页面 → 双引擎真实生成'
LOG_FILE="$PROJECT_DIR/logs/bootstrap-runtime.log"
WORKER="$PROJECT_DIR/scripts/repair-runtime-assets.sh"
if command -v setsid >/dev/null 2>&1; then
  nohup setsid bash "$WORKER" >> "$LOG_FILE" 2>&1 < /dev/null &
else
  nohup bash "$WORKER" >> "$LOG_FILE" 2>&1 < /dev/null &
fi
BOOT_PID=$!
disown "$BOOT_PID" 2>/dev/null || true
echo "[3/4] worker PID=${BOOT_PID}；等待真正的新后台上线"

# BaoTa used to show “deploy success” immediately after merely starting a background
# process. That was misleading. From now on exit 0 only after the live HTTP page is
# the new dual-engine console. The long Kokoro/Edge audio selfcheck can continue after.
LIVE=0
for _ in {1..90}; do
  HEALTH="$(curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)"
  if printf '%s' "$HEALTH" | grep -q '"console":"dual-engine-v2"'; then
    PAGE="$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
    if printf '%s' "$PAGE" | grep -q 'Kokoro 本地试听' && printf '%s' "$PAGE" | grep -q 'Edge 在线试听'; then
      LIVE=1
      break
    fi
  fi
  sleep 1
done

if [ "$LIVE" -eq 1 ]; then
  echo '[4/4] [OK] 新版双引擎后台已经真实在线：Kokoro 本地试听 + Edge 在线试听'
  echo '[Project5] 后台 worker 会继续完成 Kokoro 中英混读 WAV + Edge MP3 的真实自检。'
  exit 0
fi

echo '[4/4] [ERROR] 90 秒内没有看到新版双引擎后台，因此本次部署不能标记成功。'
echo '[Project5] 后台 worker 仍可能继续修复；最近部署日志：'
tail -n 120 "$LOG_FILE" || true
exit 1
