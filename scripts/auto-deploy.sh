#!/usr/bin/env bash
# Project5 fast deploy entry for BaoTa Git auto-deploy.
# Important: BaoTa may mark scripts that run for ~60s as failed. Large model files
# and pip installs are therefore handled by bootstrap-runtime.sh in the background.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p logs data/audio models

echo "=============================================="
echo " Project5 · Fast Auto Deploy"
echo "=============================================="

PYTHON_BIN=""
for candidate in python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
    PYTHON_BIN="$candidate"
    break
  fi
done
if [ -z "$PYTHON_BIN" ]; then
  echo "[ERROR] 需要 Python 3.10+"
  exit 1
fi

echo "[1/3] Python: $($PYTHON_BIN --version)"

MODEL_FILE="models/kokoro-v1.1-zh.int8.onnx"
VOICES_FILE="models/voices-v1.1-zh.bin"
CONFIG_FILE="models/config.json"
REQ_HASH="$(sha256sum requirements.txt | awk '{print $1}')"
OLD_HASH="$(cat .requirements.sha256 2>/dev/null || true)"

file_ready() {
  local path="$1" min_bytes="$2" size=0
  if [ -f "$path" ]; then size="$(stat -c%s "$path" 2>/dev/null || echo 0)"; fi
  [ "$size" -ge "$min_bytes" ]
}

RUNTIME_READY=1
[ -x .venv/bin/python ] || RUNTIME_READY=0
[ "$REQ_HASH" = "$OLD_HASH" ] || RUNTIME_READY=0
file_ready "$MODEL_FILE" 100000000 || RUNTIME_READY=0
file_ready "$VOICES_FILE" 50000000 || RUNTIME_READY=0
file_ready "$CONFIG_FILE" 1000 || RUNTIME_READY=0
if [ "$RUNTIME_READY" -eq 1 ] && ! .venv/bin/python -c 'import kokoro_onnx, onnxruntime, misaki' >/dev/null 2>&1; then
  RUNTIME_READY=0
fi

ensure_env() {
  if [ -f .env ]; then return 0; fi
  local admin_key
  admin_key="admin-p5-$($PYTHON_BIN -c 'import secrets; print(secrets.token_urlsafe(32))')"
  cat > .env <<EOF
PROJECT5_PORT=8005
ADMIN_KEY=${admin_key}
KOKORO_THREADS=8
KOKORO_ONNX_MODEL=${PROJECT_DIR}/models/kokoro-v1.1-zh.int8.onnx
KOKORO_ONNX_VOICES=${PROJECT_DIR}/models/voices-v1.1-zh.bin
KOKORO_ONNX_CONFIG=${PROJECT_DIR}/models/config.json
MAX_TEXT_LENGTH=5000
EOF
  chmod 600 .env
  echo "[2/3] 已创建 .env"
}

ensure_env

if [ "$RUNTIME_READY" -eq 0 ]; then
  echo "[2/3] 首次运行资源尚未全部就绪。"
  echo "      大模型/依赖不再阻塞宝塔 Webhook，而是在后台继续准备。"

  BOOT_PID_FILE="logs/bootstrap.pid"
  if [ -f "$BOOT_PID_FILE" ] && kill -0 "$(cat "$BOOT_PID_FILE")" 2>/dev/null; then
    echo "[3/3] 后台初始化已在运行 PID=$(cat "$BOOT_PID_FILE")"
  else
    nohup bash scripts/bootstrap-runtime.sh >> logs/bootstrap.log 2>&1 &
    BOOT_PID=$!
    echo "$BOOT_PID" > "$BOOT_PID_FILE"
    echo "[3/3] 已启动后台初始化 PID=${BOOT_PID}"
  fi

  echo "[OK] Webhook 快速返回成功。首次初始化进度："
  echo "     tail -f $PROJECT_DIR/logs/bootstrap.log"
  echo "初始化完成后脚本会自动重启 Project5，无需重复点部署。"
  exit 0
fi

echo "[2/3] 依赖、模型、103 音色包均已缓存"
echo "[3/3] 轻量重启 Project5"
bash scripts/restart.sh

set -a
source .env
set +a
PORT="${PROJECT5_PORT:-8005}"
for i in {1..20}; do
  if .venv/bin/python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${PORT}/health', timeout=2).read()" >/dev/null 2>&1; then
    echo "Deploy success: $(date '+%Y-%m-%d %H:%M:%S')" >> logs/deploy.log
    echo "[SUCCESS] Project5：http://127.0.0.1:${PORT}"
    exit 0
  fi
  sleep 1
done

echo "[ERROR] 服务健康检查失败"
tail -n 100 logs/app.log || true
exit 1
