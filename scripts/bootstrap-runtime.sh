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
printf '%s\n' ' Project5 · Dual TTS Bootstrap + End-to-End Selfcheck'
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
echo "[1/10] Python: $($PYTHON_BIN --version)"

CURRENT_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
if [ -f "$PROJECT_DIR/logs/last-selfcheck.json" ]; then
  LAST_OK="$(SELF_PATH="$PROJECT_DIR/logs/last-selfcheck.json" CURRENT_COMMIT="$CURRENT_COMMIT" "$PYTHON_BIN" - <<'PY' 2>/dev/null || true
import json, os
try:
    with open(os.environ['SELF_PATH'], encoding='utf-8') as f:
        d = json.load(f)
    print('yes' if d.get('status') == 'success' and d.get('commit') == os.environ['CURRENT_COMMIT'] else 'no')
except Exception:
    print('no')
PY
)"
  if [ "$LAST_OK" = "yes" ]; then
    echo "[Project5] 当前 commit=${CURRENT_COMMIT} 已通过双引擎全链路自检，跳过重复部署"
    exit 0
  fi
fi

if ! command -v espeak-ng >/dev/null 2>&1; then
  echo '[2/10] 安装系统 espeak-ng（同时保留 Python espeakng-loader 兜底）'
  if command -v dnf >/dev/null 2>&1; then dnf install -y espeak-ng || true
  elif command -v yum >/dev/null 2>&1; then yum install -y espeak-ng || true
  elif command -v apt-get >/dev/null 2>&1; then apt-get update -y && apt-get install -y espeak-ng || true
  fi
else
  echo '[2/10] espeak-ng 已安装'
fi

if [ ! -x .venv/bin/python ]; then
  echo '[3/10] 创建 .venv'
  "$PYTHON_BIN" -m venv .venv
else
  echo '[3/10] 复用 .venv'
fi

if ! .venv/bin/python -m pip --version >/dev/null 2>&1; then
  .venv/bin/python -m ensurepip --upgrade || true
fi
.venv/bin/python -m pip install -q --upgrade pip setuptools wheel

REQ_HASH="$(sha256sum requirements.txt | awk '{print $1}')"
OLD_HASH="$(cat .requirements.sha256 2>/dev/null || true)"
if [ "$REQ_HASH" != "$OLD_HASH" ] || ! .venv/bin/python - <<'PY' >/dev/null 2>&1
import edge_tts, espeakng_loader, kokoro_onnx, onnxruntime, phonemizer
from misaki.espeak import EspeakFallback
from misaki.zh import ZHG2P
ZHG2P(version='1.1', en_callable=lambda text: 'test')
EspeakFallback(british=False, version='1.1')
PY
then
  echo '[4/10] 安装/更新 Kokoro + 中英 G2P + Edge TTS 依赖'
  .venv/bin/python -m pip uninstall -y kokoro >/dev/null 2>&1 || true
  .venv/bin/python -m pip install -r requirements.txt
  echo "$REQ_HASH" > .requirements.sha256
else
  echo '[4/10] 双引擎 Python 依赖已就绪'
fi

.venv/bin/python - <<'PY' >/dev/null
import edge_tts, espeakng_loader, phonemizer
from misaki.espeak import EspeakFallback
from misaki.zh import ZHG2P
fallback = EspeakFallback(british=False, version='1.1')
def en_callable(text):
    from types import SimpleNamespace
    return fallback(SimpleNamespace(text=text))[0] or ''
ZHG2P(version='1.1', en_callable=en_callable)
PY
echo '[4/10] 中英混读 G2P + Edge TTS 导入验证通过'

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
    echo "[5/10] ${label} 已存在 ($(du -h "$dest" | awk '{print $1}'))"
    return 0
  fi

  echo "[5/10] 下载 ${label}"
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
  echo "[5/10] ${label} 下载完成 ($(du -h "$dest" | awk '{print $1}'))"
}

download_atomic "$MODEL_FILE" 300000000 "$MODEL_URL" 'Kokoro v1.1-zh 官方中文 FP32 ONNX'
download_atomic "$VOICES_FILE" 53000000 "$VOICES_URL" 'Kokoro v1.1-zh 103 音色包'
download_atomic "$CONFIG_FILE" 1000 "$CONFIG_URL" 'Kokoro v1.1-zh config.json'

ACTUAL_BYTES="$(stat -c%s "$MODEL_FILE")"
ACTUAL_SHA="$(sha256sum "$MODEL_FILE" | awk '{print $1}')"
if [ "$ACTUAL_BYTES" -ne "$MODEL_BYTES" ] || [ "$ACTUAL_SHA" != "$MODEL_SHA256" ]; then
  echo "[ERROR] FP32 模型校验失败：bytes=${ACTUAL_BYTES} sha256=${ACTUAL_SHA}"
  rm -f "$MODEL_FILE"
  exit 1
fi
echo '[5/10] FP32 模型大小与 SHA256 校验通过'

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
echo '[6/10] 运行配置已更新'

SELFTEST_JSON="$PROJECT_DIR/logs/last-selfcheck.json"
write_selfcheck() {
  local status="$1" stage="$2" message="$3" task_id="${4:-}"
  SELF_STATUS="$status" SELF_STAGE="$stage" SELF_MESSAGE="$message" SELF_TASK_ID="$task_id" SELF_PATH="$SELFTEST_JSON" SELF_COMMIT="$CURRENT_COMMIT" .venv/bin/python - <<'PY'
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

MIXED_TEXT='今天我们测试 LangChain、RAG、Agent、MCP、LLM 和 API 的中英文混合语音。'
KOKORO_DIRECT="$PROJECT_DIR/data/audio/deploy-kokoro-mixed-selftest.wav"
EDGE_DIRECT="$PROJECT_DIR/data/audio/deploy-edge-mixed-selftest.mp3"
rm -f "$KOKORO_DIRECT" "$EDGE_DIRECT"
write_selfcheck running direct_dual "正在执行 Kokoro 中英混读 + Edge 在线双引擎直连自检"

echo '[7/10] Kokoro 中英混读真实生成'
PROJECT_DIR="$PROJECT_DIR" MIXED_TEXT="$MIXED_TEXT" .venv/bin/python - <<'PY'
from pathlib import Path
import os, time
from app.dual_tts import generate_kokoro
root = Path(os.environ['PROJECT_DIR'])
out = root / 'data' / 'audio' / 'deploy-kokoro-mixed-selftest.wav'
start = time.perf_counter()
duration = generate_kokoro(os.environ['MIXED_TEXT'], 'zf_001', 1.0, out)
if not out.exists() or out.stat().st_size <= 44:
    raise RuntimeError('Kokoro mixed-language selftest WAV is empty')
print(f'[SELFTEST-KOKORO] OK elapsed={time.perf_counter()-start:.2f}s audio={duration:.2f}s bytes={out.stat().st_size}')
PY
[ -s "$KOKORO_DIRECT" ] || { write_selfcheck failed direct_kokoro "Kokoro 中英混读没有生成 WAV"; exit 1; }

echo '[8/10] Edge TTS 中英混读真实生成'
PROJECT_DIR="$PROJECT_DIR" MIXED_TEXT="$MIXED_TEXT" .venv/bin/python - <<'PY'
from pathlib import Path
import os, time
from app.dual_tts import generate_edge
root = Path(os.environ['PROJECT_DIR'])
out = root / 'data' / 'audio' / 'deploy-edge-mixed-selftest.mp3'
start = time.perf_counter()
duration = generate_edge(os.environ['MIXED_TEXT'], 'zh-CN-XiaoxiaoNeural', 1.0, out)
if not out.exists() or out.stat().st_size <= 512:
    raise RuntimeError('Edge mixed-language selftest MP3 is empty')
print(f'[SELFTEST-EDGE] OK elapsed={time.perf_counter()-start:.2f}s audio={duration:.2f}s bytes={out.stat().st_size}')
PY
[ -s "$EDGE_DIRECT" ] || { write_selfcheck failed direct_edge "Edge TTS 没有生成 MP3，请检查服务器外网连接"; exit 1; }

write_selfcheck running api_startup "Kokoro/Edge 直连均成功，正在重启双引擎 API"
echo '[9/10] 重启 Project5 API'
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
  tail -n 180 logs/app.log || true
  exit 1
fi

echo '[10/10] 通过真实 HTTP API 同时提交 Kokoro + Edge 两个任务'
write_selfcheck running api_dual_generation "API ready，正在执行双引擎 HTTP 生成测试"

KOKORO_SUBMIT="$(curl -fsS -X POST "http://127.0.0.1:${PORT}/admin/speech" \
  -H "X-Admin-Key: ${ADMIN_KEY}" -H 'Content-Type: application/json' \
  --data '{"input":"今天测试 LangChain、RAG、Agent、MCP 和 API。","engine":"kokoro","voice":"zf_001","speed":1.0}')"
EDGE_SUBMIT="$(curl -fsS -X POST "http://127.0.0.1:${PORT}/admin/speech" \
  -H "X-Admin-Key: ${ADMIN_KEY}" -H 'Content-Type: application/json' \
  --data '{"input":"今天测试 LangChain、RAG、Agent、MCP 和 API。","engine":"edge","voice":"zh-CN-XiaoxiaoNeural","speed":1.0}')"

KOKORO_TASK="$(printf '%s' "$KOKORO_SUBMIT" | .venv/bin/python -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
EDGE_TASK="$(printf '%s' "$EDGE_SUBMIT" | .venv/bin/python -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
if [ -z "$KOKORO_TASK" ] || [ -z "$EDGE_TASK" ]; then
  write_selfcheck failed api_dual_generation "双引擎 API 没有同时返回 task_id"
  echo "[ERROR] Kokoro submit=$KOKORO_SUBMIT"
  echo "[ERROR] Edge submit=$EDGE_SUBMIT"
  exit 1
fi

echo "[SELFTEST-API] kokoro=${KOKORO_TASK} edge=${EDGE_TASK}"
write_selfcheck running api_dual_generation "双引擎任务已创建，等待两边都 completed" "${KOKORO_TASK},${EDGE_TASK}"

K_DONE=0
E_DONE=0
for i in {1..600}; do
  K_JSON="$(curl -fsS -H "X-Admin-Key: ${ADMIN_KEY}" "http://127.0.0.1:${PORT}/admin/tasks/${KOKORO_TASK}" 2>/dev/null || true)"
  E_JSON="$(curl -fsS -H "X-Admin-Key: ${ADMIN_KEY}" "http://127.0.0.1:${PORT}/admin/tasks/${EDGE_TASK}" 2>/dev/null || true)"

  K_STATUS="$(printf '%s' "$K_JSON" | .venv/bin/python -c 'import json,sys
try: print(json.load(sys.stdin).get("status",""))
except Exception: print("")')"
  E_STATUS="$(printf '%s' "$E_JSON" | .venv/bin/python -c 'import json,sys
try: print(json.load(sys.stdin).get("status",""))
except Exception: print("")')"

  if [ "$K_STATUS" = "failed" ]; then
    ERR="$(printf '%s' "$K_JSON" | .venv/bin/python -c 'import json,sys; print(json.load(sys.stdin).get("error","unknown"))')"
    write_selfcheck failed api_kokoro "$ERR" "$KOKORO_TASK"
    echo "[ERROR] Kokoro API 自检失败: $ERR"
    tail -n 180 logs/app.log || true
    exit 1
  fi
  if [ "$E_STATUS" = "failed" ]; then
    ERR="$(printf '%s' "$E_JSON" | .venv/bin/python -c 'import json,sys; print(json.load(sys.stdin).get("error","unknown"))')"
    write_selfcheck failed api_edge "$ERR" "$EDGE_TASK"
    echo "[ERROR] Edge API 自检失败: $ERR"
    tail -n 180 logs/app.log || true
    exit 1
  fi

  [ "$K_STATUS" = "completed" ] && K_DONE=1
  [ "$E_STATUS" = "completed" ] && E_DONE=1

  if [ "$K_DONE" -eq 1 ] && [ "$E_DONE" -eq 1 ]; then
    K_FILE="$(printf '%s' "$K_JSON" | .venv/bin/python -c 'import json,sys; print(json.load(sys.stdin).get("audio_filename",""))')"
    E_FILE="$(printf '%s' "$E_JSON" | .venv/bin/python -c 'import json,sys; print(json.load(sys.stdin).get("audio_filename",""))')"
    K_BYTES="$(stat -c%s "$PROJECT_DIR/data/audio/$K_FILE" 2>/dev/null || echo 0)"
    E_BYTES="$(stat -c%s "$PROJECT_DIR/data/audio/$E_FILE" 2>/dev/null || echo 0)"
    if [ "$K_BYTES" -le 44 ] || [ "$E_BYTES" -le 512 ]; then
      write_selfcheck failed api_dual_generation "任务 completed 但音频文件无效" "${KOKORO_TASK},${EDGE_TASK}"
      exit 1
    fi
    write_selfcheck success complete "Kokoro 中英混读 + Edge 在线 TTS + 双引擎 API 全部真实生成成功；kokoro=${K_BYTES}B edge=${E_BYTES}B" "${KOKORO_TASK},${EDGE_TASK}"
    echo "[SUCCESS] Kokoro task=${KOKORO_TASK} file=${K_FILE} bytes=${K_BYTES}"
    echo "[SUCCESS] Edge task=${EDGE_TASK} file=${E_FILE} bytes=${E_BYTES}"
    echo "Bootstrap success: $(date '+%Y-%m-%d %H:%M:%S') kokoro=${KOKORO_TASK} edge=${EDGE_TASK}" >> logs/deploy.log
    echo '[SUCCESS] Project5 双引擎全链路自检通过'
    exit 0
  fi
  sleep 1
done

write_selfcheck failed api_dual_generation "双引擎 API 自检 600 秒内没有全部完成" "${KOKORO_TASK},${EDGE_TASK}"
echo '[ERROR] 双引擎 API 自检超时'
tail -n 180 logs/app.log || true
exit 1
