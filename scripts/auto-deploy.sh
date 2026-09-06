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
echo "[1/5] Python: $($PYTHON_BIN --version)"

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
set_env_value MELO_PORT 8016
set_env_value MELO_THREADS 4
chmod 600 .env
set -a
source .env
set +a
PORT="${PROJECT5_PORT:-8005}"

echo '[2/5] 启动 Kokoro/Edge 部署 worker'
LOG_FILE="$PROJECT_DIR/logs/bootstrap-runtime.log"
WORKER="$PROJECT_DIR/scripts/repair-runtime-assets.sh"
if command -v setsid >/dev/null 2>&1; then nohup setsid bash "$WORKER" >> "$LOG_FILE" 2>&1 < /dev/null &
else nohup bash "$WORKER" >> "$LOG_FILE" 2>&1 < /dev/null & fi
BOOT_PID=$!
disown "$BOOT_PID" 2>/dev/null || true

echo '[3/5] 后台安装/启动独立 MeloTTS CPU runtime（首次安装较久，不阻塞页面上线）'
MELO_LOG="$PROJECT_DIR/logs/melo-setup.log"
if command -v setsid >/dev/null 2>&1; then nohup setsid bash "$PROJECT_DIR/scripts/setup-melo.sh" >> "$MELO_LOG" 2>&1 < /dev/null &
else nohup bash "$PROJECT_DIR/scripts/setup-melo.sh" >> "$MELO_LOG" 2>&1 < /dev/null & fi
MELO_PID=$!
disown "$MELO_PID" 2>/dev/null || true

echo "[4/5] deploy worker=${BOOT_PID} melo-setup=${MELO_PID}；等待三引擎新版页面真实上线"
LIVE=0
for _ in {1..120}; do
  PAGE="$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
  if printf '%s' "$PAGE" | grep -q 'Kokoro 本地试听' \
    && printf '%s' "$PAGE" | grep -q 'MeloTTS 本地试听' \
    && printf '%s' "$PAGE" | grep -q 'Edge 在线试听'; then
    LIVE=1
    break
  fi
  sleep 1
done

if [ "$LIVE" -eq 1 ]; then
  echo '[5/5] [OK] 新版三引擎后台已在线：Kokoro + MeloTTS + Edge'
  echo '[Project5] MeloTTS 首次依赖/模型准备继续在后台进行，可在页面查看“运行时已启动/模型已加载”。'
  exit 0
fi

echo '[5/5] [ERROR] 120 秒内没有看到新版三引擎后台，因此本次部署不能标记成功。'
echo '[Project5] 最近主部署日志：'
tail -n 100 "$LOG_FILE" || true
echo '[Project5] 最近 MeloTTS 安装日志：'
tail -n 60 "$MELO_LOG" || true
exit 1
