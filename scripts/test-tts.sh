#!/usr/bin/env bash
set -u

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

printf '\n==============================================\n'
printf ' Project5 TTS Speed Diagnostic\n'
printf '==============================================\n'

if [ ! -x .venv/bin/python ]; then
  echo '[FAIL] .venv/bin/python 不存在，请先完成部署。'
  exit 1
fi

PORT=8005
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
  PORT="${PROJECT5_PORT:-8005}"
fi

echo "[1/4] 检查服务：http://127.0.0.1:${PORT}/health"
if curl -fsS "http://127.0.0.1:${PORT}/health"; then
  echo
  echo '[OK] FastAPI 服务正常'
else
  echo
  echo '[WARN] FastAPI 健康检查失败；仍继续测试 Kokoro 引擎。'
fi

echo
echo '[2/4] ONNX 引擎直接测速（连续两次；第二次包含 G2P 缓存收益）'
.venv/bin/python - <<'PY'
from pathlib import Path
import time
import traceback

from app.tts import engine

text = '你好，这是 Project5 的中文语音速度测试，三十个字左右应该很快完成。'
print(
    f'backend={getattr(engine, "backend", "unknown")}, '
    f'loaded={engine.loaded}, loading={getattr(engine, "loading", False)}, device={engine.device}'
)

try:
    for i in (1, 2):
        out = Path(f'data/audio/diagnostic_speed_{i}.wav')
        started = time.perf_counter()
        duration = engine.generate(text, 'zf_001', 1.0, out)
        elapsed = time.perf_counter() - started
        rtf = elapsed / duration if duration else 0
        print(
            f'[RUN {i}] elapsed={elapsed:.3f}s  audio={duration:.3f}s  '
            f'RTF={rtf:.3f}  size={out.stat().st_size} bytes'
        )
        print(f'[RUN {i}] metrics={getattr(engine, "last_metrics", {})}')
except Exception as exc:
    print(f'[FAIL] Kokoro ONNX 直接推理失败: {type(exc).__name__}: {exc}')
    traceback.print_exc()
    raise SystemExit(21)
PY
ENGINE_CODE=$?

if [ "$ENGINE_CODE" -ne 0 ]; then
  echo
  echo '[RESULT] 问题在 Kokoro ONNX 推理/依赖层。把上面的 traceback 发给我。'
  exit "$ENGINE_CODE"
fi

echo
echo '[3/4] 通过本机 FastAPI 测速 /admin/speech（绕过 Nginx）'
if [ -z "${ADMIN_KEY:-}" ]; then
  echo '[FAIL] .env 中没有 ADMIN_KEY，无法执行本机 API 测试。'
  exit 22
fi

RESP_FILE="$(mktemp)"
CURL_META="$(curl -sS --max-time 120 -o "$RESP_FILE" -w 'HTTP=%{http_code} TOTAL=%{time_total}s' \
  -X POST "http://127.0.0.1:${PORT}/admin/speech" \
  -H "X-Admin-Key: ${ADMIN_KEY}" \
  -H 'Content-Type: application/json' \
  --data '{"input":"你好，这是 Project5 的 API 速度测试语音。","voice":"zf_001","speed":1.0}' || true)"

echo "$CURL_META"
cat "$RESP_FILE"
echo
HTTP_CODE="$(printf '%s' "$CURL_META" | sed -n 's/.*HTTP=\([0-9][0-9][0-9]\).*/\1/p')"
rm -f "$RESP_FILE"

if [ "$HTTP_CODE" != '200' ]; then
  echo '[RESULT] ONNX 引擎能生成，但 FastAPI 接口失败。把 HTTP 返回和 logs/app.log 最后 80 行发给我。'
  exit 23
fi

echo
echo '[4/4] 最近 TTS 性能日志'
grep '\[Project5\]\[TTS\]' logs/app.log 2>/dev/null | tail -n 5 || true

echo
echo '[RESULT] 测速完成。重点看 RUN 2 的 elapsed 和 RTF：'
echo 'RTF < 1 代表生成速度快于音频播放时长；越小越快。'
