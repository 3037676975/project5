#!/usr/bin/env bash
# Project5 自动部署脚本
# 宝塔 Git 自动部署会先 git pull，再执行本脚本；这里不重复拉取代码。
# 不使用 Docker：Python venv + 单进程 Uvicorn + 本地 ONNX INT8 模型。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p logs data/audio models

echo "=============================================="
echo " Project5 · Kokoro-82M-v1.1-zh ONNX Deploy"
echo "=============================================="

# 1) 找到 Python 3.10+
PYTHON_BIN=""
for candidate in python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
    PYTHON_BIN="$candidate"
    break
  fi
done
if [ -z "$PYTHON_BIN" ]; then
  echo "[ERROR] 需要 Python 3.10+。请先在服务器安装 Python 3.10/3.11/3.12。"
  exit 1
fi
echo "[1/7] Python: $($PYTHON_BIN --version)"

# 2) 中文 G2P / 英文回退需要 espeak-ng
if ! command -v espeak-ng >/dev/null 2>&1; then
  echo "[2/7] 安装 espeak-ng"
  if command -v dnf >/dev/null 2>&1; then dnf install -y espeak-ng || true
  elif command -v yum >/dev/null 2>&1; then yum install -y espeak-ng || true
  elif command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y espeak-ng || true
  fi
else
  echo "[2/7] espeak-ng 已安装"
fi
if ! command -v espeak-ng >/dev/null 2>&1; then
  echo "[WARN] espeak-ng 尚未安装；纯中文可工作，但中英混合文本可能受影响。"
fi

# 3) 独立虚拟环境 + 自动修复 pip
if [ ! -x .venv/bin/python ]; then
  echo "[3/7] 创建 Python 虚拟环境"
  "$PYTHON_BIN" -m venv .venv
else
  echo "[3/7] 复用现有 .venv"
fi

bootstrap_pip() {
  if .venv/bin/python -m pip --version >/dev/null 2>&1; then
    return 0
  fi
  echo "[3/7] 检测到 .venv 缺少 pip，正在自动修复"
  if .venv/bin/python -m ensurepip --upgrade >/dev/null 2>&1; then
    echo "[3/7] 已通过 ensurepip 修复 pip"
    return 0
  fi
  echo "[3/7] ensurepip 不可用，重新创建 .venv"
  rm -rf .venv
  "$PYTHON_BIN" -m venv .venv || true
  if [ -x .venv/bin/python ] && .venv/bin/python -m ensurepip --upgrade >/dev/null 2>&1; then
    echo "[3/7] 重建 .venv 后 pip 已恢复"
    return 0
  fi
  echo "[3/7] 使用 PyPA get-pip.py 兜底安装 pip"
  TMP_GET_PIP="$(mktemp /tmp/project5-get-pip.XXXXXX.py)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 https://bootstrap.pypa.io/get-pip.py -o "$TMP_GET_PIP"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TMP_GET_PIP" https://bootstrap.pypa.io/get-pip.py
  else
    echo "[ERROR] 服务器没有 curl/wget，且 Python ensurepip 不可用。"
    rm -f "$TMP_GET_PIP"
    exit 1
  fi
  .venv/bin/python "$TMP_GET_PIP"
  rm -f "$TMP_GET_PIP"
}

bootstrap_pip
.venv/bin/python -m pip install -q --upgrade pip setuptools wheel

# 4) 安装 ONNX CPU 依赖。requirements 未变化时完全跳过。
REQ_HASH="$(sha256sum requirements.txt | awk '{print $1}')"
OLD_HASH="$(cat .requirements.sha256 2>/dev/null || true)"
if [ "$REQ_HASH" != "$OLD_HASH" ]; then
  echo "[4/7] 切换到 ONNX CPU 推理依赖"
  # 清理旧参考 PyTorch 后端，避免同名 misaki 文件冲突；Project5 venv 为独立环境。
  .venv/bin/python -m pip uninstall -y kokoro misaki torch >/dev/null 2>&1 || true
  .venv/bin/python -m pip install -r requirements.txt
  echo "$REQ_HASH" > .requirements.sha256
else
  echo "[4/7] requirements 未变化，跳过安装"
fi

# 5) 模型只下载一次。运行时不再从 Hugging Face 临时下载模型/单个音色。
MODEL_FILE="models/kokoro-v1.1-zh.int8.onnx"
VOICES_FILE="models/voices-v1.1-zh.bin"
CONFIG_FILE="models/config.json"
MODEL_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/kokoro-v1.1-zh.int8.onnx"
VOICES_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/voices-v1.1-zh.bin"
CONFIG_URL="https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh/resolve/main/config.json"

download_if_needed() {
  local dest="$1"
  local min_bytes="$2"
  local url="$3"
  local label="$4"
  local size=0
  if [ -f "$dest" ]; then
    size="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
  fi
  if [ "$size" -ge "$min_bytes" ]; then
    echo "[5/7] ${label} 已缓存 ($(du -h "$dest" | awk '{print $1}'))"
    return 0
  fi

  echo "[5/7] 下载 ${label}（首次部署一次，后续复用）"
  local tmp="${dest}.part"
  rm -f "$tmp"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 5 --retry-delay 2 --connect-timeout 20 -o "$tmp" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=5 --timeout=20 -O "$tmp" "$url"
  else
    echo "[ERROR] 缺少 curl/wget，无法下载 ${label}"
    exit 1
  fi
  size="$(stat -c%s "$tmp" 2>/dev/null || echo 0)"
  if [ "$size" -lt "$min_bytes" ]; then
    echo "[ERROR] ${label} 下载不完整，只有 ${size} bytes"
    rm -f "$tmp"
    exit 1
  fi
  mv "$tmp" "$dest"
  echo "[5/7] ${label} 下载完成 ($(du -h "$dest" | awk '{print $1}'))"
}

download_if_needed "$MODEL_FILE" 100000000 "$MODEL_URL" "Kokoro v1.1-zh INT8 模型"
download_if_needed "$VOICES_FILE" 50000000 "$VOICES_URL" "103 音色包"
download_if_needed "$CONFIG_FILE" 1000 "$CONFIG_URL" "模型配置"

# 6) 首次部署自动生成管理密钥，不提交到 GitHub
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
  echo "[6/7] 已创建 .env；管理密钥保存在 $PROJECT_DIR/.env"
else
  echo "[6/7] 复用现有 .env（ONNX 路径有代码默认值，无需改旧配置）"
fi

# 7) 轻量重启，不重建容器
bash scripts/restart.sh
set -a
source .env
set +a
PORT="${PROJECT5_PORT:-8005}"
for i in {1..30}; do
  if .venv/bin/python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${PORT}/health', timeout=2).read()" >/dev/null 2>&1; then
    DATE="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "Deploy success: $DATE" >> logs/deploy.log
    echo "[7/7] 部署完成，后端：http://127.0.0.1:${PORT}"
    echo "推理后端：Kokoro-82M-v1.1-zh · ONNX Runtime INT8 · CPU"
    exit 0
  fi
  sleep 1
done

echo "[ERROR] 服务健康检查失败，最近日志："
tail -n 120 logs/app.log || true
exit 1
