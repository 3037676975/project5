#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p logs data/audio models

printf '%s\n' '=============================================='
printf '%s\n' ' Project5 · Webhook Deploy Dispatcher'
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

# Legacy/background workers from older commits must not compete with the main
# deployment lock. Kokoro already has a built-in lightweight English fallback,
# so the optional heavy English enhancement is never part of webhook deployment.
pkill -f "$PROJECT_DIR/scripts/setup-kokoro-english.sh" >/dev/null 2>&1 || true
pkill -f 'scripts/build-voice-previews.py' >/dev/null 2>&1 || true
pkill -f 'scripts/setup-melo.sh' >/dev/null 2>&1 || true
bash "$PROJECT_DIR/scripts/stop-melo.sh" >/dev/null 2>&1 || true

echo '[2/4] 已清理旧的 English/preview/Melo 后台 worker'
echo '[3/4] 启动唯一的主部署流程；bootstrap.lock 会自动串行多个 Webhook'

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

# Do not make 宝塔/Webhook wait for model download, pip, model preload and a real
# TTS self-test. Those can legitimately take several minutes on an 8-core CPU and
# previously caused a false "部署失败" after 120 seconds even while deployment was
# still progressing normally in the background.
sleep 1
if kill -0 "$BOOT_PID" >/dev/null 2>&1; then
  echo "[4/4] [OK] Webhook 已接收，主部署 worker=${BOOT_PID} 正在后台执行"
  echo '[Project5] 完整部署结果会写入 logs/bootstrap-runtime.log 和 /runtime.selfcheck。'
  echo '[Project5] 不再自动启动 Kokoro-English 安装脚本，也不会自动批量生成试听。'
  exit 0
fi

# A very fast worker can also exit 0 because this commit is already deployed.
# If it exited immediately, inspect the latest log instead of blindly marking fail.
if tail -n 80 "$LOG_FILE" 2>/dev/null | grep -qE '\[OK\]|已通过自检|新版控制台已在线'; then
  echo '[4/4] [OK] 主部署已快速完成或当前版本已经在线'
  exit 0
fi

echo '[4/4] [ERROR] 主部署 worker 启动后立即异常退出'
tail -n 120 "$LOG_FILE" || true
exit 1
