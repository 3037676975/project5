#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p logs data/audio models

printf '%s\n' '=============================================='
printf '%s\n' ' Project5 · Fast Auto Deploy'
printf '%s\n' '=============================================='

PYTHON_BIN=""
for candidate in python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
    PYTHON_BIN="$candidate"
    break
  fi
done
[ -n "$PYTHON_BIN" ] || { echo '[ERROR] 需要 Python 3.10+'; exit 1; }
echo "[1/3] Python: $($PYTHON_BIN --version)"

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

echo '[2/3] 配置已写入；保持当前 API 继续运行，先由 worker 自检新版本'

# Do not restart the live API here. bootstrap-runtime.sh verifies the model,
# creates a real WAV directly, then restarts the API and performs a second real
# HTTP generation test. A bad commit therefore cannot immediately replace the
# currently running API before it has passed the deployment checks.
LOG_FILE="$PROJECT_DIR/logs/bootstrap-runtime.log"
if command -v setsid >/dev/null 2>&1; then
  nohup setsid bash "$PROJECT_DIR/scripts/bootstrap-runtime.sh" >> "$LOG_FILE" 2>&1 < /dev/null &
else
  nohup bash "$PROJECT_DIR/scripts/bootstrap-runtime.sh" >> "$LOG_FILE" 2>&1 < /dev/null &
fi
BOOT_PID=$!
disown "$BOOT_PID" 2>/dev/null || true

echo "[3/3] 已启动自检部署 worker PID=${BOOT_PID}"
echo "[OK] Webhook 立即返回；worker 会按顺序执行：模型校验 → 直连生成 → 重启 API → HTTP 异步生成 → WAV 校验。"
exit 0
