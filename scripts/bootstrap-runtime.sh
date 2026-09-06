#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p logs data/audio models

exec 9>"$PROJECT_DIR/logs/bootstrap.lock"
if command -v flock >/dev/null 2>&1; then
  echo "[Project5] 等待部署锁，避免多个 Webhook 同时部署"
  flock 9
fi

printf '%s\n' '================================================'
printf '%s\n' ' Project5 · Deploy + Running-Version Verification'
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
echo "[1/8] Python: $($PYTHON_BIN --version)"

CURRENT_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
SELFTEST_JSON="$PROJECT_DIR/logs/last-selfcheck.json"

write_selfcheck() {
  local status="$1" stage="$2" message="$3" task_id="${4:-}"
  SELF_STATUS="$status" SELF_STAGE="$stage" SELF_MESSAGE="$message" SELF_TASK_ID="$task_id" SELF_PATH="$SELFTEST_JSON" SELF_COMMIT="$CURRENT_COMMIT" "$PYTHON_BIN" - <<'PY'
import json, os
from datetime import datetime
data = {
    'status': os.environ['SELF_STATUS'],
    'stage': os.environ['SELF_STAGE'],
    'message': os.environ['SELF_MESSAGE'],
    'task_id': os.environ.get('SELF_TASK_ID') or None,
    'commit': os.environ.get('SELF_COMMIT') or None,
    'updated_at': datetime.now().isoformat(timespec='seconds'),
}
with open(os.environ['SELF_PATH'], 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False)
PY
}

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
PORT="${PROJECT5_PORT:-8005}"

# A successful JSON marker alone is not enough. The previous deploy flow could leave
# an old Uvicorn process alive and accidentally self-test that old process.
if [ -f "$SELFTEST_JSON" ]; then
  LAST_OK="$(SELF_PATH="$SELFTEST_JSON" CURRENT_COMMIT="$CURRENT_COMMIT" "$PYTHON_BIN" - <<'PY' 2>/dev/null || true
import json, os
try:
    with open(os.environ['SELF_PATH'], encoding='utf-8') as f:
        d=json.load(f)
    print('yes' if d.get('status')=='success' and d.get('commit')==os.environ['CURRENT_COMMIT'] else 'no')
except Exception:
    print('no')
PY
)"
  if [ "$LAST_OK" = "yes" ]; then
    LIVE_HEALTH="$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/health" 2>/dev/null || true)"
    LIVE_PAGE="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
    if printf '%s' "$LIVE_HEALTH" | grep -q '"console":"dual-engine-v2"' \
      && printf '%s' "$LIVE_PAGE" | grep -q 'Kokoro 本地试听' \
      && printf '%s' "$LIVE_PAGE" | grep -q 'Edge 在线试听'; then
      echo "[Project5] 当前 commit=${CURRENT_COMMIT} 已通过自检，而且线上确实是 dual-engine-v2，跳过重复部署"
      exit 0
    fi
    echo '[Project5] selfcheck 文件虽然成功，但线上仍是旧页面；强制继续部署'
  fi
fi

if [ ! -x .venv/bin/python ]; then
  echo '[2/8] 创建 .venv'
  "$PYTHON_BIN" -m venv .venv
else
  echo '[2/8] 复用 .venv'
fi
.venv/bin/python -m ensurepip --upgrade >/dev/null 2>&1 || true
.venv/bin/python -m pip install -q --upgrade pip setuptools wheel

REQ_HASH="$(sha256sum requirements.txt | awk '{print $1}')"
OLD_HASH="$(cat .requirements.sha256 2>/dev/null || true)"
if [ "$REQ_HASH" != "$OLD_HASH" ] || ! .venv/bin/python - <<'PY' >/dev/null 2>&1
import edge_tts, espeakng_loader, kokoro_onnx, onnxruntime, phonemizer
from misaki.espeak import EspeakFallback
from misaki.zh import ZHG2P
fallback = EspeakFallback(british=False, version='1.1')
ZHG2P(version='1.1', en_callable=lambda text: fallback(type('T', (), {'text': text})())[0] or '')
PY
then
  echo '[3/8] 安装/更新双引擎依赖'
  .venv/bin/python -m pip uninstall -y kokoro >/dev/null 2>&1 || true
  .venv/bin/python -m pip install -r requirements.txt
  echo "$REQ_HASH" > .requirements.sha256
else
  echo '[3/8] 双引擎依赖已就绪'
fi

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
  if [ "$size" -ge "$min_bytes" ]; then echo "[4/8] ${label} 已存在"; return 0; fi
  echo "[4/8] 下载 ${label}"
  rm -f "$tmp"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 12 --retry-all-errors --retry-delay 2 --connect-timeout 20 --speed-time 60 --speed-limit 1024 -o "$tmp" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=12 --timeout=30 -O "$tmp" "$url"
  else
    echo '[ERROR] 缺少 curl/wget'; exit 1
  fi
  size="$(stat -c%s "$tmp" 2>/dev/null || echo 0)"
  [ "$size" -ge "$min_bytes" ] || { echo "[ERROR] ${label} 下载不完整：${size}"; rm -f "$tmp"; exit 1; }
  mv -f "$tmp" "$dest"
}

download_atomic "$MODEL_FILE" 300000000 "$MODEL_URL" 'Kokoro FP32 ONNX'
download_atomic "$VOICES_FILE" 53000000 "$VOICES_URL" 'Kokoro 103 音色包'
download_atomic "$CONFIG_FILE" 1000 "$CONFIG_URL" 'Kokoro config.json'

ACTUAL_BYTES="$(stat -c%s "$MODEL_FILE")"
ACTUAL_SHA="$(sha256sum "$MODEL_FILE" | awk '{print $1}')"
if [ "$ACTUAL_BYTES" -ne "$MODEL_BYTES" ] || [ "$ACTUAL_SHA" != "$MODEL_SHA256" ]; then
  write_selfcheck failed model_verify 'FP32 模型大小或 SHA256 不正确'
  echo "[ERROR] FP32 模型校验失败 bytes=${ACTUAL_BYTES} sha256=${ACTUAL_SHA}"
  exit 1
fi
echo '[4/8] Kokoro 模型校验通过'

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
set_env_value KOKORO_ONNX_MODEL "${PROJECT_DIR}/${MODEL_FILE}"
set_env_value KOKORO_ONNX_VOICES "${PROJECT_DIR}/${VOICES_FILE}"
set_env_value KOKORO_ONNX_CONFIG "${PROJECT_DIR}/${CONFIG_FILE}"
chmod 600 .env
set -a
# shellcheck disable=SC1091
source .env
set +a
PORT="${PROJECT5_PORT:-8005}"

echo '[5/8] 强制替换旧 Uvicorn，并验证新版控制台'
write_selfcheck running restart_console '正在停止旧进程并启动 dual-engine-v2 控制台'
bash scripts/restart.sh

PAGE_TMP="$(mktemp)"
trap 'rm -f "$PAGE_TMP"' EXIT
curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/" -o "$PAGE_TMP" || { write_selfcheck failed console_verify '根页面无法访问'; exit 1; }
if ! grep -q 'Kokoro 本地试听' "$PAGE_TMP" || ! grep -q 'Edge 在线试听' "$PAGE_TMP"; then
  write_selfcheck failed console_verify '根页面不是新版双引擎控制台'
  echo '[ERROR] 根页面仍不是新版控制台'
  exit 1
fi
echo '[5/8] 新版控制台已在线：Kokoro 本地试听 + Edge 在线试听'

write_selfcheck running model_ready '新版页面已生效，等待 Kokoro 本地模型 ready'
echo '[6/8] 等待 Kokoro 模型 ready'
READY=0
for _ in {1..240}; do
  STATE="$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/runtime" 2>/dev/null || true)"
  if printf '%s' "$STATE" | grep -q '"state":"ready"'; then READY=1; break; fi
  sleep 1
done
if [ "$READY" -ne 1 ]; then
  write_selfcheck failed model_ready 'Kokoro 在 240 秒内没有进入 ready'
  echo '[ERROR] Kokoro 没有进入 ready'
  tail -n 160 logs/app.log || true
  exit 1
fi

echo '[7/8] 通过真实 API 生成 Kokoro 中英混合 WAV + Edge MP3'
write_selfcheck running api_dual_generation '正在通过真实 API 生成 Kokoro 与 Edge 音频'
MIXED='今天测试 LangChain、RAG、Agent、MCP、LLM 和 API。'
K_SUBMIT="$(curl -fsS -X POST "http://127.0.0.1:${PORT}/admin/speech" -H "X-Admin-Key: ${ADMIN_KEY}" -H 'Content-Type: application/json' --data "{\"input\":\"${MIXED}\",\"engine\":\"kokoro\",\"voice\":\"zf_001\",\"speed\":1.0}")"
E_SUBMIT="$(curl -fsS -X POST "http://127.0.0.1:${PORT}/admin/speech" -H "X-Admin-Key: ${ADMIN_KEY}" -H 'Content-Type: application/json' --data "{\"input\":\"${MIXED}\",\"engine\":\"edge\",\"voice\":\"zh-CN-XiaoxiaoNeural\",\"speed\":1.0}")"
K_TASK="$(printf '%s' "$K_SUBMIT" | .venv/bin/python -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))')"
E_TASK="$(printf '%s' "$E_SUBMIT" | .venv/bin/python -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))')"
[ -n "$K_TASK" ] && [ -n "$E_TASK" ] || { write_selfcheck failed api_submit '双引擎没有返回 task_id'; exit 1; }
write_selfcheck running api_dual_generation '双引擎任务已创建，等待 completed' "${K_TASK},${E_TASK}"

K_DONE=0
E_DONE=0
K_JSON=''
E_JSON=''
for _ in {1..600}; do
  K_JSON="$(curl -fsS --max-time 3 -H "X-Admin-Key: ${ADMIN_KEY}" "http://127.0.0.1:${PORT}/admin/tasks/${K_TASK}" 2>/dev/null || true)"
  E_JSON="$(curl -fsS --max-time 3 -H "X-Admin-Key: ${ADMIN_KEY}" "http://127.0.0.1:${PORT}/admin/tasks/${E_TASK}" 2>/dev/null || true)"
  K_STATUS="$(printf '%s' "$K_JSON" | .venv/bin/python -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))' 2>/dev/null || true)"
  E_STATUS="$(printf '%s' "$E_JSON" | .venv/bin/python -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))' 2>/dev/null || true)"
  if [ "$K_STATUS" = "failed" ]; then
    K_ERR="$(printf '%s' "$K_JSON" | .venv/bin/python -c 'import json,sys; print(json.load(sys.stdin).get("error", ""))' 2>/dev/null || true)"
    write_selfcheck failed api_kokoro "$K_ERR" "$K_TASK"; echo "[ERROR] Kokoro: $K_ERR"; exit 1
  fi
  if [ "$E_STATUS" = "failed" ]; then
    E_ERR="$(printf '%s' "$E_JSON" | .venv/bin/python -c 'import json,sys; print(json.load(sys.stdin).get("error", ""))' 2>/dev/null || true)"
    write_selfcheck failed api_edge "$E_ERR" "$E_TASK"; echo "[ERROR] Edge: $E_ERR"; exit 1
  fi
  [ "$K_STATUS" = "completed" ] && K_DONE=1
  [ "$E_STATUS" = "completed" ] && E_DONE=1
  [ "$K_DONE" -eq 1 ] && [ "$E_DONE" -eq 1 ] && break
  sleep 1
done

if [ "$K_DONE" -ne 1 ] || [ "$E_DONE" -ne 1 ]; then
  write_selfcheck failed api_timeout '600 秒内双引擎没有全部完成' "${K_TASK},${E_TASK}"
  exit 1
fi

K_FILE="$(printf '%s' "$K_JSON" | .venv/bin/python -c 'import json,sys; print(json.load(sys.stdin).get("audio_filename", ""))')"
E_FILE="$(printf '%s' "$E_JSON" | .venv/bin/python -c 'import json,sys; print(json.load(sys.stdin).get("audio_filename", ""))')"
[[ "$K_FILE" == *.wav ]] && [ -s "$PROJECT_DIR/data/audio/$K_FILE" ] || { write_selfcheck failed api_kokoro_file 'Kokoro completed 但 WAV 不存在'; exit 1; }
[[ "$E_FILE" == *.mp3 ]] && [ -s "$PROJECT_DIR/data/audio/$E_FILE" ] || { write_selfcheck failed api_edge_file 'Edge completed 但 MP3 不存在'; exit 1; }

write_selfcheck success complete '部署成功：新版双引擎页面已生效，Kokoro 中英混合 WAV 与 Edge MP3 均真实生成成功' "${K_TASK},${E_TASK}"
echo '[8/8] SUCCESS'
echo "[Project5] 新版控制台已生效；Kokoro=${K_FILE}；Edge=${E_FILE}"
