#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p logs data/audio models

# Prevent duplicate bootstrap jobs without relying on stale PID files.
exec 9>"$PROJECT_DIR/logs/bootstrap.lock"
if command -v flock >/dev/null 2>&1; then
  if ! flock -n 9; then
    echo "[Project5] bootstrap 已有实例运行，当前任务退出。"
    exit 0
  fi
fi

printf '%s\n' '================================================'
printf '%s\n' ' Project5 · Runtime Bootstrap'
printf '%s\n' " $(date '+%Y-%m-%d %H:%M:%S')"
printf '%s\n' '================================================'

PYTHON_BIN=""
for candidate in python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
    PYTHON_BIN="$candidate"
    break
  fi
done
[ -n "$PYTHON_BIN" ] || { echo '[ERROR] 需要 Python 3.10+'; exit 1; }
echo "[1/7] Python: $($PYTHON_BIN --version)"

if ! command -v espeak-ng >/dev/null 2>&1; then
  echo '[2/7] 安装 espeak-ng'
  if command -v dnf >/dev/null 2>&1; then dnf install -y espeak-ng || true
  elif command -v yum >/dev/null 2>&1; then yum install -y espeak-ng || true
  elif command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y espeak-ng || true
  fi
else
  echo '[2/7] espeak-ng 已安装'
fi

if [ ! -x .venv/bin/python ]; then
  echo '[3/7] 创建 .venv'
  "$PYTHON_BIN" -m venv .venv
else
  echo '[3/7] 复用 .venv'
fi

if ! .venv/bin/python -m pip --version >/dev/null 2>&1; then
  .venv/bin/python -m ensurepip --upgrade || true
fi
.venv/bin/python -m pip install -q --upgrade pip setuptools wheel

REQ_HASH="$(sha256sum requirements.txt | awk '{print $1}')"
OLD_HASH="$(cat .requirements.sha256 2>/dev/null || true)"
if [ "$REQ_HASH" != "$OLD_HASH" ] || ! .venv/bin/python -c 'import kokoro_onnx, onnxruntime; from misaki.zh import ZHG2P; ZHG2P(version="1.1")' >/dev/null 2>&1; then
  echo '[4/7] 安装/更新 Kokoro ONNX CPU 依赖'
  .venv/bin/python -m pip uninstall -y kokoro torch >/dev/null 2>&1 || true
  .venv/bin/python -m pip install -r requirements.txt
  echo "$REQ_HASH" > .requirements.sha256
else
  echo '[4/7] Python 依赖已就绪'
fi

if ! .venv/bin/python -c 'from misaki.zh import ZHG2P; ZHG2P(version="1.1")' >/dev/null 2>&1; then
  echo '[4/7] 修复 Misaki 中文 G2P'
  .venv/bin/python -m pip uninstall -y misaki misaki-fork >/dev/null 2>&1 || true
  SITE_PACKAGES="$(.venv/bin/python -c 'import site; print(site.getsitepackages()[0])')"
  rm -rf "$SITE_PACKAGES/misaki" "$SITE_PACKAGES"/misaki-*.dist-info "$SITE_PACKAGES"/misaki_fork-*.dist-info
  .venv/bin/python -m pip install --no-cache-dir --force-reinstall 'misaki-fork[zh]==0.9.6'
fi
.venv/bin/python -c 'from misaki.zh import ZHG2P; ZHG2P(version="1.1")' >/dev/null
echo '[4/7] 中文 G2P 验证通过'

MODEL_FILE="models/kokoro-v1.1-zh.onnx"
VOICES_FILE="models/voices-v1.1-zh.bin"
CONFIG_FILE="models/config.json"
MODEL_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/kokoro-v1.1-zh.onnx"
VOICES_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/voices-v1.1-zh.bin"
CONFIG_URL="https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh/resolve/main/config.json"
MODEL_SHA256="859f9ded9f53be16c24857cdab3254a45da53c3afd5ba6ef134c7de3f822e326"
MODEL_BYTES=325506167

download_atomic() {
  local dest="$1" min_bytes="$2" url="$3" label="$4"
  local tmp="${dest}.part" size=0
  if [ -f "$dest" ]; then size="$(stat -c%s "$dest" 2>/dev/null || echo 0)"; fi
  if [ "$size" -ge "$min_bytes" ]; then
    echo "[5/7] ${label} 已存在 ($(du -h "$dest" | awk '{print $1}'))"
    return 0
  fi

  echo "[5/7] 下载 ${label}"
  rm -f "$tmp"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 12 --retry-all-errors --retry-delay 2 --connect-timeout 20 --speed-time 60 --speed-limit 1024 -o "$tmp" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=12 --timeout=30 -O "$tmp" "$url"
  else
    echo '[ERROR] 缺少 curl/wget'
    exit 1
  fi
  size="$(stat -c%s "$tmp" 2>/dev/null || echo 0)"
  if [ "$size" -lt "$min_bytes" ]; then
    echo "[ERROR] ${label} 下载不完整：${size} bytes"
    rm -f "$tmp"
    exit 1
  fi
  mv -f "$tmp" "$dest"
  echo "[5/7] ${label} 下载完成 ($(du -h "$dest" | awk '{print $1}'))"
}

download_atomic "$MODEL_FILE" 300000000 "$MODEL_URL" 'Kokoro v1.1-zh 官方中文 FP32 ONNX'
download_atomic "$VOICES_FILE" 53000000 "$VOICES_URL" 'Kokoro v1.1-zh 音色包'
download_atomic "$CONFIG_FILE" 1000 "$CONFIG_URL" 'Kokoro v1.1-zh config.json'

ACTUAL_BYTES="$(stat -c%s "$MODEL_FILE")"
ACTUAL_SHA="$(sha256sum "$MODEL_FILE" | awk '{print $1}')"
if [ "$ACTUAL_BYTES" -ne "$MODEL_BYTES" ] || [ "$ACTUAL_SHA" != "$MODEL_SHA256" ]; then
  echo "[ERROR] FP32 模型校验失败：bytes=${ACTUAL_BYTES} sha256=${ACTUAL_SHA}"
  rm -f "$MODEL_FILE"
  exit 1
fi
echo '[5/7] FP32 模型大小与 SHA256 校验通过'

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
set_env_value KOKORO_ONNX_MODEL "${PROJECT_DIR}/${MODEL_FILE}"
set_env_value KOKORO_ONNX_VOICES "${PROJECT_DIR}/${VOICES_FILE}"
set_env_value KOKORO_ONNX_CONFIG "${PROJECT_DIR}/${CONFIG_FILE}"
chmod 600 .env
echo '[6/7] 运行配置已更新'

# Upstream-style smoke test before touching the running API.
SELFTEST_FILE="$PROJECT_DIR/data/audio/deploy-selftest.wav"
rm -f "$SELFTEST_FILE"
echo '[6/7] 执行官方中文链路自测并生成 deploy-selftest.wav'
PROJECT_DIR="$PROJECT_DIR" .venv/bin/python - <<'PY'
from pathlib import Path
import os, time
import soundfile as sf
from misaki.zh import ZHG2P
from kokoro_onnx import Kokoro

root = Path(os.environ['PROJECT_DIR'])
model = root / 'models' / 'kokoro-v1.1-zh.onnx'
voices = root / 'models' / 'voices-v1.1-zh.bin'
config = root / 'models' / 'config.json'
out = root / 'data' / 'audio' / 'deploy-selftest.wav'

start = time.perf_counter()
g2p = ZHG2P(version='1.1')
kokoro = Kokoro(str(model), str(voices), vocab_config=str(config))
phonemes, _ = g2p('千里之行，始于足下。')
samples, sample_rate = kokoro.create(phonemes, voice='zf_001', speed=1.0, is_phonemes=True)
sf.write(str(out), samples, sample_rate)
elapsed = time.perf_counter() - start
print(f'[SELFTEST] OK elapsed={elapsed:.2f}s file={out} bytes={out.stat().st_size}')
PY
[ -s "$SELFTEST_FILE" ] || { echo '[ERROR] 官方中文自测没有生成音频'; exit 1; }

echo '[7/7] 自测成功，重启 Project5 API'
bash scripts/restart.sh

set -a
source .env
set +a
PORT="${PROJECT5_PORT:-8005}"
for i in {1..180}; do
  STATE="$(curl -fsS "http://127.0.0.1:${PORT}/runtime" 2>/dev/null || true)"
  if printf '%s' "$STATE" | grep -q '"state":"ready"'; then
    echo "[SUCCESS] Project5 API + Kokoro FP32 已就绪：http://127.0.0.1:${PORT}"
    echo "Bootstrap success: $(date '+%Y-%m-%d %H:%M:%S')" >> logs/deploy.log
    exit 0
  fi
  sleep 1
done

echo '[ERROR] 自测音频成功，但 API 在 180 秒内未进入 ready'
curl -s "http://127.0.0.1:${PORT}/runtime" || true
echo
tail -n 120 logs/app.log || true
exit 1
