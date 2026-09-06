#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p logs data/audio models

printf '%s\n' '=============================================='
printf '%s\n' ' Project5 · BaoTa Verified Auto Deploy'
printf '%s\n' '=============================================='

PYTHON_BIN=""
for candidate in python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
    PYTHON_BIN="$candidate"
    break
  fi
done
[ -n "$PYTHON_BIN" ] || { echo '[ERROR] 需要 Python 3.10+'; exit 1; }
echo "[1/5] Python: $($PYTHON_BIN --version)"

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

verify_console() {
  local health page
  health="$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)"
  printf '%s' "$health" | grep -q '"console":"dual-engine-v2"' || return 1
  page="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
  printf '%s' "$page" | grep -q 'Kokoro 本地试听' || return 1
  printf '%s' "$page" | grep -q 'Edge 在线试听' || return 1
  return 0
}

echo '[2/5] 先切换到刚刚 git pull 下来的最新后台，不等待耗时的模型自检'
QUICK_LIVE=0
if [ -x .venv/bin/python ]; then
  if bash scripts/restart.sh; then
    for _ in {1..30}; do
      if verify_console; then QUICK_LIVE=1; break; fi
      sleep 1
    done
  fi
else
  echo '[Project5] 首次部署还没有 .venv，交给后台 worker 初始化后再上线'
fi

if [ "$QUICK_LIVE" -eq 1 ]; then
  echo '[3/5] [OK] 最新 dual-engine-v2 控制台已经在线'
else
  echo '[3/5] 快速切换尚未成功；启动完整修复 worker 后继续等待'
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
echo "[4/5] 完整修复/双引擎自检 worker PID=${BOOT_PID} 已启动"

# If the quick switch worked, BaoTa can safely report success now: the browser is
# already serving the new code. Heavy dependency/model/audio checks continue in the
# detached worker and will write logs/last-selfcheck.json.
if [ "$QUICK_LIVE" -eq 1 ]; then
  echo '[5/5] [OK] 宝塔部署完成：新版页面已真实生效；后台继续执行 Kokoro + Edge 语音自检。'
  exit 0
fi

# First deployment / dependency-repair fallback. Give the worker enough time to
# install missing packages and start the new console. We no longer fail after only
# 90 seconds while pip/model checks are still legitimately running.
for _ in {1..240}; do
  if verify_console; then
    echo '[5/5] [OK] 完整修复后新版 dual-engine-v2 控制台已经真实在线。'
    exit 0
  fi
  if ! kill -0 "$BOOT_PID" 2>/dev/null; then
    echo '[Project5] 部署 worker 已退出但新版页面仍未上线；输出最近日志。'
    tail -n 160 "$LOG_FILE" || true
    exit 1
  fi
  sleep 1
done

echo '[5/5] [ERROR] 240 秒后新版后台仍未上线。最近部署日志：'
tail -n 160 "$LOG_FILE" || true
exit 1
