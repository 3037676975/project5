#!/usr/bin/env bash
# Project5 one-time/runtime bootstrap.
# This script may take several minutes on first run and is intentionally launched
# in the background by auto-deploy.sh so BaoTa's webhook timeout does not mark a
# healthy deployment as failed.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p logs data/audio models
PID_FILE="logs/bootstrap.pid"

cleanup() {
  rm -f "$PID_FILE"
}
trap cleanup EXIT

echo "================================================"
echo " Project5 · Background Runtime Bootstrap"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================"

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
echo "[1/6] Python: $($PYTHON_BIN --version)"

if ! command -v espeak-ng >/dev/null 2>&1; then
  echo "[2/6] 安装 espeak-ng"
  if command -v dnf >/dev/null 2>&1; then dnf install -y espeak-ng || true
  elif command -v yum >/dev/null 2>&1; then yum install -y espeak-ng || true
  elif command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y espeak-ng || true
  fi
else
  echo "[2/6] espeak-ng 已安装"
fi

if [ ! -x .venv/bin/python ]; then
  echo "[3/6] 创建 .venv"
  "$PYTHON_BIN" -m venv .venv
else
  echo "[3/6] 复用 .venv"
fi

if ! .venv/bin/python -m pip --version >/dev/null 2>&1; then
  .venv/bin/python -m ensurepip --upgrade || true
fi
if ! .venv/bin/python -m pip --version >/dev/null 2>&1; then
  echo "[3/6] ensurepip 不可用，使用 get-pip.py"
  TMP_GET_PIP="$(mktemp /tmp/project5-get-pip.XXXXXX.py)"
  curl -fsSL --retry 5 https://bootstrap.pypa.io/get-pip.py -o "$TMP_GET_PIP"
  .venv/bin/python "$TMP_GET_PIP"
  rm -f "$TMP_GET_PIP"
fi
.venv/bin/python -m pip install -q --upgrade pip setuptools wheel

REQ_HASH="$(sha256sum requirements.txt | awk '{print $1}')"
OLD_HASH="$(cat .requirements.sha256 2>/dev/null || true)"
RUNTIME_IMPORT_TEST='import kokoro_onnx, onnxruntime; from misaki.zh import ZHG2P; ZHG2P(version="1.1")'
if [ "$REQ_HASH" != "$OLD_HASH" ] || ! .venv/bin/python -c "$RUNTIME_IMPORT_TEST" >/dev/null 2>&1; then
  echo "[4/6] 安装/更新 ONNX CPU 依赖"
  .venv/bin/python -m pip uninstall -y kokoro torch >/dev/null 2>&1 || true
  .venv/bin/python -m pip install -r requirements.txt
  echo "$REQ_HASH" > .requirements.sha256
else
  echo "[4/6] 依赖已就绪"
fi

# A previous environment can contain the old `misaki` distribution together with
# `misaki-fork`. Both expose the same top-level package name and can leave a broken
# namespace package behind. Project5 needs the Chinese submodule specifically.
if ! .venv/bin/python -c 'from misaki.zh import ZHG2P; ZHG2P(version="1.1")' >/dev/null 2>&1; then
  echo "[4/6] 检测到 Misaki 中文模块冲突，执行一次干净修复"
  .venv/bin/python -m pip uninstall -y misaki misaki-fork >/dev/null 2>&1 || true
  SITE_PACKAGES="$(.venv/bin/python -c 'import site; print(site.getsitepackages()[0])')"
  rm -rf "$SITE_PACKAGES/misaki" "$SITE_PACKAGES"/misaki-*.dist-info "$SITE_PACKAGES"/misaki_fork-*.dist-info
  .venv/bin/python -m pip install --no-cache-dir --force-reinstall 'misaki-fork[zh]==0.9.6'
fi

if ! .venv/bin/python -c 'from misaki.zh import ZHG2P; ZHG2P(version="1.1")' >/dev/null 2>&1; then
  echo "[ERROR] Misaki 中文 G2P 仍不可用"
  .venv/bin/python -c 'import misaki, sys; print("misaki=", misaki); print("sys.path=", sys.path); from misaki.zh import ZHG2P' || true
  exit 1
fi
echo "[4/6] Misaki 中文 G2P 验证通过"

MODEL_FILE="models/kokoro-v1.1-zh.int8.onnx"
VOICES_FILE="models/voices-v1.1-zh.bin"
CONFIG_FILE="models/config.json"
MODEL_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/kokoro-v1.1-zh.int8.onnx"
VOICES_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/voices-v1.1-zh.bin"
CONFIG_URL="https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh/resolve/main/config.json"

download_atomic() {
  local dest="$1"
  local min_bytes="$2"
  local url="$3"
  local label="$4"
  local tmp="${dest}.part"
  local size=0

  if [ -f "$dest" ]; then
    size="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
  fi
  if [ "$size" -ge "$min_bytes" ]; then
    echo "[5/6] ${label} 已缓存 ($(du -h "$dest" | awk '{print $1}'))"
    return 0
  fi

  echo "[5/6] 下载 ${label}（后台下载，完成后原子替换）"
  rm -f "$tmp"

  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 10 --retry-all-errors --retry-delay 2 --connect-timeout 20 -o "$tmp" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=10 --timeout=20 -O "$tmp" "$url"
  else
    echo "[ERROR] 缺少 curl/wget"
    return 1
  fi

  size="$(stat -c%s "$tmp" 2>/dev/null || echo 0)"
  if [ "$size" -lt "$min_bytes" ]; then
    echo "[ERROR] ${label} 下载不完整：${size} bytes"
    rm -f "$tmp"
    return 1
  fi

  mv -f "$tmp" "$dest"
  echo "[5/6] ${label} 完成 ($(du -h "$dest" | awk '{print $1}'))"
}

download_atomic "$MODEL_FILE" 100000000 "$MODEL_URL" "Kokoro v1.1-zh INT8 模型"
download_atomic "$VOICES_FILE" 53000000 "$VOICES_URL" "103 音色包"
download_atomic "$CONFIG_FILE" 1000 "$CONFIG_URL" "模型配置"

if [ ! -f .env ]; then
  ADMIN_KEY="admin-p5-$($PYTHON_BIN -c 'import secrets; print(secrets.token_urlsafe(32))')"
  cat > .env <<EOF
PROJECT5_PORT=8005
ADMIN_KEY=${ADMIN_KEY}
KOKORO_THREADS=8
KOKORO_ONNX_MODEL=${PROJECT_DIR}/models/kokoro-v1.1-zh.int8.onnx
KOKORO_ONNX_VOICES=${PROJECT_DIR}/models/voices-v1.1-zh.bin
KOKORO_ONNX_CONFIG=${PROJECT_DIR}/models/config.json
MAX_TEXT_LENGTH=5000
EOF
  chmod 600 .env
  echo "[6/6] 已创建 .env"
else
  echo "[6/6] 复用 .env"
fi

echo "[Project5] 依赖与模型全部就绪，重启服务"
bash scripts/restart.sh

set -a
source .env
set +a
PORT="${PROJECT5_PORT:-8005}"
echo "[Project5] 等待 Kokoro ONNX 完成加载与预热……"
for i in {1..180}; do
  if .venv/bin/python -c "import json,urllib.request; d=json.load(urllib.request.urlopen('http://127.0.0.1:${PORT}/health', timeout=2)); raise SystemExit(0 if d.get('model_loaded') is True else 1)" >/dev/null 2>&1; then
    echo "[SUCCESS] Project5 模型已就绪：http://127.0.0.1:${PORT}"
    echo "Bootstrap success: $(date '+%Y-%m-%d %H:%M:%S')" >> logs/deploy.log
    exit 0
  fi
  sleep 1
done

echo "[ERROR] Web 服务已启动，但 Kokoro 模型在 180 秒内未就绪"
echo "===== /health ====="
curl -s "http://127.0.0.1:${PORT}/health" || true
echo
echo "===== app.log ====="
tail -n 160 logs/app.log || true
exit 1
