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
if [ -z "$PYTHON_BIN" ]; then
  echo '[ERROR] 需要 Python 3.10+'
  exit 1
fi

echo "[1/3] Python: $($PYTHON_BIN --version)"

# Project5 intentionally uses the FP32 export on this server. The INT8 export
# fails in CPUExecutionProvider with NOT_IMPLEMENTED / GemmInteger(10).
MODEL_FILE="models/kokoro-v1.1-zh.onnx"
VOICES_FILE="models/voices-v1.1-zh.bin"
CONFIG_FILE="models/config.json"
REQ_HASH="$(sha256sum requirements.txt | awk '{print $1}')"
OLD_HASH="$(cat .requirements.sha256 2>/dev/null || true)"

file_ready() {
  local path="$1" min_bytes="$2" size=0
  [ -f "$path" ] && size="$(stat -c%s "$path" 2>/dev/null || echo 0)"
  [ "$size" -ge "$min_bytes" ]
}

set_env_value() {
  local key="$1" value="$2"
  if grep -q "^${key}=" .env 2>/dev/null; then
    sed -i "s#^${key}=.*#${key}=${value}#" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

ensure_env() {
  if [ ! -f .env ]; then
    local admin_key
    admin_key="admin-p5-$($PYTHON_BIN -c 'import secrets; print(secrets.token_urlsafe(32))')"
    cat > .env <<EOF
PROJECT5_PORT=8005
ADMIN_KEY=${admin_key}
KOKORO_THREADS=8
KOKORO_INTER_THREADS=1
KOKORO_ONNX_MODEL=${PROJECT_DIR}/${MODEL_FILE}
KOKORO_ONNX_VOICES=${PROJECT_DIR}/${VOICES_FILE}
KOKORO_ONNX_CONFIG=${PROJECT_DIR}/${CONFIG_FILE}
MAX_TEXT_LENGTH=5000
EOF
  fi

  # Migrate existing installs away from the incompatible INT8 model without
  # touching ADMIN_KEY or other user settings.
  set_env_value KOKORO_THREADS 8
  set_env_value KOKORO_INTER_THREADS 1
  set_env_value KOKORO_ONNX_MODEL "${PROJECT_DIR}/${MODEL_FILE}"
  set_env_value KOKORO_ONNX_VOICES "${PROJECT_DIR}/${VOICES_FILE}"
  set_env_value KOKORO_ONNX_CONFIG "${PROJECT_DIR}/${CONFIG_FILE}"
  chmod 600 .env
}

ensure_env

RUNTIME_READY=1
[ -x .venv/bin/python ] || RUNTIME_READY=0
[ "$REQ_HASH" = "$OLD_HASH" ] || RUNTIME_READY=0
file_ready "$MODEL_FILE" 300000000 || RUNTIME_READY=0
file_ready "$VOICES_FILE" 53000000 || RUNTIME_READY=0
file_ready "$CONFIG_FILE" 1000 || RUNTIME_READY=0
if [ "$RUNTIME_READY" -eq 1 ] && ! .venv/bin/python -c 'import kokoro_onnx, onnxruntime; from misaki.zh import ZHG2P; ZHG2P(version="1.1")' >/dev/null 2>&1; then
  RUNTIME_READY=0
fi

if [ "$RUNTIME_READY" -eq 0 ]; then
  echo '[2/3] FP32 模型或运行环境尚未就绪，后台准备资源。'
  BOOT_PID_FILE="logs/bootstrap.pid"
  if [ -f "$BOOT_PID_FILE" ] && kill -0 "$(cat "$BOOT_PID_FILE")" 2>/dev/null; then
    echo "[3/3] 后台初始化已运行 PID=$(cat "$BOOT_PID_FILE")"
  else
    nohup bash scripts/bootstrap-runtime.sh >> logs/bootstrap.log 2>&1 &
    BOOT_PID=$!
    echo "$BOOT_PID" > "$BOOT_PID_FILE"
    echo "[3/3] 已启动后台初始化 PID=${BOOT_PID}"
  fi
  echo "[OK] 宝塔 Webhook 先返回；进度：tail -f $PROJECT_DIR/logs/bootstrap.log"
  exit 0
fi

echo '[2/3] FP32 模型、103 音色包、依赖均已就绪'
echo '[3/3] 重启 Project5'
bash scripts/restart.sh

set -a
source .env
set +a
PORT="${PROJECT5_PORT:-8005}"
for i in {1..45}; do
  if .venv/bin/python -c "import json,urllib.request; d=json.load(urllib.request.urlopen('http://127.0.0.1:${PORT}/runtime', timeout=2)); raise SystemExit(0 if d.get('state') == 'ready' else 1)" >/dev/null 2>&1; then
    echo "Deploy success: $(date '+%Y-%m-%d %H:%M:%S')" >> logs/deploy.log
    echo "[SUCCESS] Project5 FP32 多核模型已就绪：http://127.0.0.1:${PORT}"
    exit 0
  fi
  sleep 1
done

echo '[WARN] Web 服务已启动，但模型尚未在 45 秒内完成加载。'
echo "查看：tail -f $PROJECT_DIR/logs/app.log"
exit 0
