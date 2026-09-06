#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p logs data/audio models

exec 9>"$PROJECT_DIR/logs/bootstrap.lock"
if command -v flock >/dev/null 2>&1; then
  echo "[Project5] 等待部署锁，避免多个 Webhook 同时修改运行环境"
  flock 9
fi

printf '%s\n' '================================================'
printf '%s\n' ' Project5 · Runtime Bootstrap + End-to-End Selfcheck'
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
echo "[1/9] Python: $($PYTHON_BIN --version)"

CURRENT_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
if [ -f "$PROJECT_DIR/logs/last-selfcheck.json" ]; then
  LAST_OK="$(SELF_PATH="$PROJECT_DIR/logs/last-selfcheck.json" CURRENT_COMMIT="$CURRENT_COMMIT" "$PYTHON_BIN" - <<'PY' 2>/dev/null || true
import json, os
try:
    with open(os.environ["SELF_PATH"], encoding="utf-8") as f:
        d = json.load(f)
    print("yes" if d.get("status") == "success" and d.get("commit") == os.environ["CURRENT_COMMIT"] else "no")
except Exception:
    print("no")
PY
)"
  if [ "$LAST_OK" = "yes" ]; then
    echo "[Project5] 当前 commit=${CURRENT_COMMIT} 已通过全链路自检，跳过重复部署"
    exit 0
  fi
fi

if ! command -v espeak-ng >/dev/null 2>&1; then
  echo '[2/9] 安装 espeak-ng'
  if command -v dnf >/dev/null 2>&1; then dnf install -y espeak-ng || true
  elif command -v yum >/dev/null 2>&1; then yum install -y espeak-ng || true
  elif command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y espeak-ng || true
  fi
else
  echo '[2/9] espeak-ng 已安装'
fi

if [ ! -x .venv/bin/python ]; then
  echo '[3/9] 创建 .venv'
  "$PYTHON_BIN" -m venv .venv
else
  echo '[3/9] 复用 .venv'
fi

if ! .venv/bin/python -m pip --version >/dev/null 2>&1; then
  .venv/bin/python -m ensurepip --upgrade || true
fi
.venv/bin/python -m pip install -q --upgrade pip setuptools wheel

REQ_HASH="$(sha256sum requirements.txt | awk '{print $1}')"
OLD_HASH="$(cat .requirements.sha256 2>/dev/null || true)"
if [ "$REQ_HASH" != "$OLD_HASH" ] || ! .venv/bin/python -c 'import kokoro_onnx, onnxruntime; from misaki.zh import ZHG2P; ZHG2P(version="1.1")' >/dev/null 2>&1; then
  echo '[4/9] 安装/更新 Kokoro ONNX CPU 依赖'
  .venv/bin/python -m pip uninstall -y kokoro torch >/dev/null 2>&1 || true
  .venv/bin/python -m pip install -r requirements.txt
  echo "$REQ_HASH" > .requirements.sha256
else
  echo '[4/9] Python 依赖已就绪'
fi

if ! .venv/bin/python -c 'from misaki.zh import ZHG2P; ZHG2P(version="1.1")' >/dev/null 2>&1; then
  echo '[4/9] 修复 Misaki 中文 G2P'
  .venv/bin/python -m pip uninstall -y misaki misaki-fork >/dev/null 2>&1 || true
  SITE_PACKAGES="$(.venv/bin/python -c 'import site; print(site.getsitepackages()[0])')"
  rm -rf "$SITE_PACKAGES/misaki" "$SITE_PACKAGES"/misaki-*.dist-info "$SITE_PACKAGES"/misaki_fork-*.dist-info
  .venv/bin/python -m pip install --no-cache-dir --force-reinstall 'misaki-fork[zh]==0.9.6'
fi
.venv/bin/python -c 'from misaki.zh import ZHG2P; ZHG2P(version="1.1")' >/dev/null
echo '[4/9] 中文 G2P 验证通过'

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
    echo "[5/9] ${label} 已存在 ($(du -h "$dest" | awk '{print $1}'))"
    return 0
  fi

  echo "[5/9] 下载 ${label}"
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
  echo "[5/9] ${label} 下载完成 ($(du -h "$dest" | awk '{print $1}'))"
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
echo '[5/9] FP32 模型大小与 SHA256 校验通过'

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
echo '[6/9] 运行配置已更新'

SELFTEST_JSON="$PROJECT_DIR/logs/last-selfcheck.json"
write_selfcheck() {
  local status="$1" stage="$2" message="$3" task_id="${4:-}"
  SELF_STATUS="$status" SELF_STAGE="$stage" SELF_MESSAGE="$message" SELF_TASK_ID="$task_id" SELF_PATH="$SELFTEST_JSON" SELF_COMMIT="$CURRENT_COMMIT" .venv/bin/python - <<'PY'
import json, os
from datetime import datetime
data = {
    "status": os.environ["SELF_STATUS"],
    "stage": os.environ["SELF_STAGE"],
    "message": os.environ["SELF_MESSAGE"],
    "task_id": os.environ.get("SELF_TASK_ID") or None,
    "commit": os.environ.get("SELF_COMMIT") or None,
    "updated_at": datetime.now().isoformat(timespec="seconds"),
}
with open(os.environ["SELF_PATH"], "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False)
PY
}

write_selfcheck running direct_model "正在执行官方中文模型直连自检"

SELFTEST_FILE="$PROJECT_DIR/data/audio/deploy-selftest.wav"
rm -f "$SELFTEST_FILE"
echo '[7/9] 执行官方中文模型直连自检'
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
if out.stat().st_size <= 44:
    raise RuntimeError('selftest WAV is empty')
print(f'[SELFTEST-DIRECT] OK elapsed={elapsed:.2f}s file={out} bytes={out.stat().st_size}')
PY
[ -s "$SELFTEST_FILE" ] || { write_selfcheck failed direct_model "官方中文模型直连自检没有生成 WAV"; exit 1; }
write_selfcheck running api_startup "模型直连自检成功，正在重启 API"

echo '[8/9] 重启 Project5 API'
bash scripts/restart.sh

set -a
source .env
set +a
PORT="${PROJECT5_PORT:-8005}"

READY=0
for i in {1..240}; do
  STATE="$(curl -fsS "http://127.0.0.1:${PORT}/runtime" 2>/dev/null || true)"
  if printf '%s' "$STATE" | grep -q '"state":"ready"'; then
    READY=1
    break
  fi
  sleep 1
done
if [ "$READY" -ne 1 ]; then
  write_selfcheck failed api_startup "API 在 240 秒内没有进入 ready"
  echo '[ERROR] API 在 240 秒内没有进入 ready'
  curl -s "http://127.0.0.1:${PORT}/runtime" || true
  echo
  tail -n 160 logs/app.log || true
  exit 1
fi

echo '[8/9] API ready，开始真实 HTTP 生成自检'
write_selfcheck running api_generation "API 已 ready，正在通过 /admin/speech 创建真实生成任务"

SUBMIT_RESPONSE="$(curl -fsS \
  -X POST "http://127.0.0.1:${PORT}/admin/speech" \
  -H "X-Admin-Key: ${ADMIN_KEY}" \
  -H 'Content-Type: application/json' \
  --data '{"input":"你好，这是 Project5 部署后的 API 生成自检。","voice":"zf_001","speed":1.0}')"

TASK_ID="$(printf '%s' "$SUBMIT_RESPONSE" | .venv/bin/python -c 'import json,sys; d=json.load(sys.stdin); print(d.get("id",""))')"
[ -n "$TASK_ID" ] || {
  write_selfcheck failed api_generation "API 没有返回 task_id"
  echo "[ERROR] /admin/speech 没有返回 task_id: $SUBMIT_RESPONSE"
  exit 1
}

echo "[SELFTEST-API] task_id=${TASK_ID}"
write_selfcheck running api_generation "真实 API 任务已创建，等待 completed" "$TASK_ID"

for i in {1..600}; do
  TASK_JSON="$(curl -fsS \
    -H "X-Admin-Key: ${ADMIN_KEY}" \
    "http://127.0.0.1:${PORT}/admin/tasks/${TASK_ID}" 2>/dev/null || true)"
  TASK_STATUS="$(printf '%s' "$TASK_JSON" | .venv/bin/python -c 'import json,sys
try:
 d=json.load(sys.stdin); print(d.get("status",""))
except Exception:
 print("")')"

  if [ "$TASK_STATUS" = "completed" ]; then
    AUDIO_FILENAME="$(printf '%s' "$TASK_JSON" | .venv/bin/python -c 'import json,sys; print(json.load(sys.stdin).get("audio_filename",""))')"
    [ -n "$AUDIO_FILENAME" ] || {
      write_selfcheck failed api_generation "任务 completed 但没有 audio_filename" "$TASK_ID"
      exit 1
    }
    API_AUDIO="$PROJECT_DIR/data/audio/$AUDIO_FILENAME"
    API_BYTES="$(stat -c%s "$API_AUDIO" 2>/dev/null || echo 0)"
    if [ "$API_BYTES" -le 44 ]; then
      write_selfcheck failed api_generation "任务 completed 但 WAV 文件无效" "$TASK_ID"
      exit 1
    fi
    write_selfcheck success complete "模型直连 + API 异步任务 + WAV 文件全部自检成功，bytes=${API_BYTES}" "$TASK_ID"
    echo "[SUCCESS] API 真实生成成功 task=${TASK_ID} file=${AUDIO_FILENAME} bytes=${API_BYTES}"
    echo "Bootstrap success: $(date '+%Y-%m-%d %H:%M:%S') task=${TASK_ID}" >> logs/deploy.log
    echo '[9/9] Project5 全链路自检通过'
    exit 0
  fi

  if [ "$TASK_STATUS" = "failed" ]; then
    TASK_ERROR="$(printf '%s' "$TASK_JSON" | .venv/bin/python -c 'import json,sys; print(json.load(sys.stdin).get("error","unknown error"))')"
    write_selfcheck failed api_generation "$TASK_ERROR" "$TASK_ID"
    echo "[ERROR] API 自检任务失败: $TASK_ERROR"
    tail -n 160 logs/app.log || true
    exit 1
  fi
  sleep 1
done

write_selfcheck failed api_generation "API 自检任务 600 秒内没有完成" "$TASK_ID"
echo "[ERROR] API 自检任务超时 task=${TASK_ID}"
tail -n 160 logs/app.log || true
exit 1
