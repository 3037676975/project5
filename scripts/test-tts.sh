#!/usr/bin/env bash
set -u

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

printf '\n==============================================\n'
printf ' Project5 TTS Diagnostic\n'
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
echo '[2/4] 直接测试 Kokoro 引擎（绕过浏览器、Nginx、FastAPI）'
.venv/bin/python - <<'PY'
from pathlib import Path
import traceback

from app.tts import engine

out = Path('data/audio/diagnostic_engine.wav')
out.parent.mkdir(parents=True, exist_ok=True)
print(f'engine.loaded={engine.loaded}, engine.loading={getattr(engine, "loading", False)}, device={engine.device}')
try:
    duration = engine.generate('你好，这是 Project5 的中文语音测试。', 'zf_001', 1.0, out)
    print(f'[OK] Kokoro 直接推理成功: {out}  duration={duration}s  size={out.stat().st_size} bytes')
except Exception as exc:
    print(f'[FAIL] Kokoro 直接推理失败: {type(exc).__name__}: {exc}')
    traceback.print_exc()
    raise SystemExit(21)
PY
ENGINE_CODE=$?

if [ "$ENGINE_CODE" -ne 0 ]; then
  echo
  echo '[RESULT] 问题在 Kokoro 推理/依赖层，不是 Nginx 或网页。把上面的 traceback 发给我。'
  exit "$ENGINE_CODE"
fi

echo
echo '[3/4] 通过本机 FastAPI 测试 /admin/speech（绕过 Nginx）'
if [ -z "${ADMIN_KEY:-}" ]; then
  echo '[FAIL] .env 中没有 ADMIN_KEY，无法执行本机 API 测试。'
  exit 22
fi

RESP_FILE="$(mktemp)"
HTTP_CODE="$(curl -sS --max-time 300 -o "$RESP_FILE" -w '%{http_code}' \
  -X POST "http://127.0.0.1:${PORT}/admin/speech" \
  -H "X-Admin-Key: ${ADMIN_KEY}" \
  -H 'Content-Type: application/json' \
  --data '{"input":"你好，这是 Project5 的 API 测试语音。","voice":"zf_001","speed":1.0}' || true)"

echo "HTTP ${HTTP_CODE}"
cat "$RESP_FILE"
echo
rm -f "$RESP_FILE"

if [ "$HTTP_CODE" != '200' ]; then
  echo '[RESULT] Kokoro 引擎能生成，但 FastAPI 接口失败。把 HTTP 返回和 logs/app.log 最后 80 行发给我。'
  exit 23
fi

echo
echo '[4/4] 检查生成文件'
ls -lh data/audio/diagnostic_engine.wav 2>/dev/null || true

echo
echo '[RESULT] Kokoro + 本机 FastAPI 都正常。'
echo '如果网页仍显示“请求失败”，问题就在宝塔/Nginx 反向代理超时或网页链路，而不是模型。'
