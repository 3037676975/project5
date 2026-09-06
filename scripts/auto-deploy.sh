#!/usr/bin/env bash
# Project5 自动部署脚本
# 宝塔 Git 自动部署会先 git pull，再执行本脚本；这里不重复拉取代码。
# 不使用 Docker：Python venv + 单进程 Uvicorn + PID 管理。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p logs data/audio

echo "=============================================="
echo " Project5 · Kokoro-82M-v1.1-zh Auto Deploy"
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
echo "[1/6] Python: $($PYTHON_BIN --version)"

# 2) 中文前处理依赖 espeak-ng，只在缺失时尝试安装一次
if ! command -v espeak-ng >/dev/null 2>&1; then
  echo "[2/6] 安装 espeak-ng"
  if command -v dnf >/dev/null 2>&1; then dnf install -y espeak-ng || true
  elif command -v yum >/dev/null 2>&1; then yum install -y espeak-ng || true
  elif command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y espeak-ng || true
  fi
else
  echo "[2/6] espeak-ng 已安装"
fi
if ! command -v espeak-ng >/dev/null 2>&1; then
  echo "[WARN] espeak-ng 尚未安装。控制台可以启动，但 TTS 生成可能失败。"
fi

# 3) 独立虚拟环境，只在第一次创建
if [ ! -x .venv/bin/python ]; then
  echo "[3/6] 创建 Python 虚拟环境"
  "$PYTHON_BIN" -m venv .venv
else
  echo "[3/6] 复用现有 .venv"
fi
.venv/bin/python -m pip install -q --upgrade pip setuptools wheel

# 4) requirements.txt 没变化就不重复安装，避免每次部署都重装模型依赖
REQ_HASH="$(sha256sum requirements.txt | awk '{print $1}')"
OLD_HASH="$(cat .requirements.sha256 2>/dev/null || true)"
if [ "$REQ_HASH" != "$OLD_HASH" ]; then
  echo "[4/6] 依赖有变化，开始安装"
  .venv/bin/pip install -r requirements.txt
  echo "$REQ_HASH" > .requirements.sha256
else
  echo "[4/6] requirements 未变化，跳过安装"
fi

# 5) 首次部署自动生成管理密钥，不提交到 GitHub
if [ ! -f .env ]; then
  ADMIN_KEY="admin-p5-$($PYTHON_BIN -c 'import secrets; print(secrets.token_urlsafe(32))')"
  cat > .env <<EOF
PROJECT5_PORT=8005
ADMIN_KEY=${ADMIN_KEY}
KOKORO_REPO_ID=hexgrad/Kokoro-82M-v1.1-zh
KOKORO_DEVICE=cpu
KOKORO_THREADS=8
MAX_TEXT_LENGTH=5000
PRELOAD_MODEL=0
EOF
  chmod 600 .env
  echo "[5/6] 已创建 .env；管理密钥保存在 $PROJECT_DIR/.env"
else
  echo "[5/6] 复用现有 .env（不会覆盖你的密钥）"
fi

# 6) 轻量重启，不重建容器
bash scripts/restart.sh
set -a
source .env
set +a
PORT="${PROJECT5_PORT:-8005}"
for i in {1..15}; do
  if .venv/bin/python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:${PORT}/health', timeout=2).read()" >/dev/null 2>&1; then
    DATE="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "Deploy success: $DATE" >> logs/deploy.log
    echo "[6/6] 部署完成，后端：http://127.0.0.1:${PORT}"
    echo "下一步：让 Nginx/宝塔站点反向代理到 127.0.0.1:${PORT}"
    exit 0
  fi
  sleep 1
done

echo "[ERROR] 服务健康检查失败，最近日志："
tail -n 100 logs/app.log || true
exit 1
