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

echo '[2/4] 已写入官方中文 FP32 模型路径'

# Important recovery path: the model may finish downloading after an older API
# process already failed its one-time background preload. In that case the browser
# can correctly see the model file on disk while the running Python process still
# keeps the old FileNotFoundError in memory. If all three runtime files are already
# present, restart the API immediately so it loads the current Git checkout and the
# now-existing model instead of waiting for another bootstrap cycle.
MODEL_FILE="$PROJECT_DIR/models/kokoro-v1.1-zh.onnx"
VOICES_FILE="$PROJECT_DIR/models/voices-v1.1-zh.bin"
CONFIG_FILE="$PROJECT_DIR/models/config.json"
MODEL_BYTES="$(stat -c%s "$MODEL_FILE" 2>/dev/null || echo 0)"
VOICES_BYTES="$(stat -c%s "$VOICES_FILE" 2>/dev/null || echo 0)"
CONFIG_BYTES="$(stat -c%s "$CONFIG_FILE" 2>/dev/null || echo 0)"

if [ "$MODEL_BYTES" -ge 300000000 ] && [ "$VOICES_BYTES" -ge 53000000 ] && [ "$CONFIG_BYTES" -ge 1000 ]; then
  echo '[3/4] 模型文件已经齐全，立即重启 API，清除旧的缺文件错误并加载最新代码'
  bash "$PROJECT_DIR/scripts/restart.sh" || true
else
  echo "[3/4] 模型尚未齐全：model=${MODEL_BYTES} voices=${VOICES_BYTES} config=${CONFIG_BYTES}，交给后台 worker 下载"
fi

# Always launch the runtime worker. The worker itself uses flock, so stale PID files
# can no longer block a deployment and simultaneous webhooks cannot run two downloads.
LOG_FILE="$PROJECT_DIR/logs/bootstrap-runtime.log"
if command -v setsid >/dev/null 2>&1; then
  nohup setsid bash "$PROJECT_DIR/scripts/bootstrap-runtime.sh" >> "$LOG_FILE" 2>&1 < /dev/null &
else
  nohup bash "$PROJECT_DIR/scripts/bootstrap-runtime.sh" >> "$LOG_FILE" 2>&1 < /dev/null &
fi
BOOT_PID=$!
disown "$BOOT_PID" 2>/dev/null || true

echo "[4/4] 已启动部署 worker PID=${BOOT_PID}"
echo "[OK] 宝塔 Webhook 可以立即返回；worker 会继续校验模型 → 官方中文自测 → 确认 API ready。"
exit 0
