#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p logs

# auto-deploy starts the base runtime and English enhancement in parallel. On a
# brand-new server .venv may not exist yet, so wait without holding bootstrap.lock;
# otherwise the English worker could block the bootstrap that is supposed to create it.
echo '[Kokoro-English] 等待主部署创建 .venv（不占部署锁）'
VENV_READY=0
for _ in {1..300}; do
  if [ -x "$PROJECT_DIR/.venv/bin/python" ]; then
    VENV_READY=1
    break
  fi
  sleep 1
done
[ "$VENV_READY" -eq 1 ] || {
  echo '[Kokoro-English][ERROR] 300 秒内主部署没有创建 .venv';
  exit 1;
}

# Now serialize any pip/model changes with the main bootstrap.
exec 9>"$PROJECT_DIR/logs/bootstrap.lock"
if command -v flock >/dev/null 2>&1; then
  echo '[Kokoro-English] 等待主部署释放 bootstrap.lock'
  flock 9
fi

PY="$PROJECT_DIR/.venv/bin/python"

printf '%s\n' '================================================'
printf '%s\n' ' Project5 · Kokoro Official English G2P Setup'
printf '%s\n' " $(date '+%Y-%m-%d %H:%M:%S')"
printf '%s\n' '================================================'

if "$PY" - <<'PY' >/dev/null 2>&1
import spacy, torch, transformers
from misaki import en
from misaki.espeak import EspeakFallback
fallback = EspeakFallback(british=False, version='1.1')
g2p = en.G2P(version='1.1', trf=False, british=False, fallback=fallback, unk='')
ps, _ = g2p('Have you ever wondered how AI generated voices work?')
assert ps and '❓' not in ps
PY
then
  echo '[Kokoro-English] 官方 Misaki English G2P 已就绪，无需重复安装'
else
  echo '[Kokoro-English] 安装 CPU PyTorch（仅供 English G2P 依赖导入，不加载第二个 TTS 模型）'
  "$PY" -m pip install --index-url https://download.pytorch.org/whl/cpu --extra-index-url https://pypi.org/simple torch

  echo '[Kokoro-English] 安装轻量英文前端依赖'
  "$PY" -m pip install 'spacy>=3.8,<4' 'transformers>=4.40,<5' 'num2words>=0.5.14,<1'

  echo '[Kokoro-English] 准备 en_core_web_sm 小型英文标注模型'
  if ! "$PY" - <<'PY' >/dev/null 2>&1
import spacy
raise SystemExit(0 if spacy.util.is_package('en_core_web_sm') else 1)
PY
  then
    "$PY" -m spacy download en_core_web_sm
  fi
fi

echo '[Kokoro-English] 验证纯英文 + 技术词 G2P'
"$PY" - <<'PY'
from misaki import en
from misaki.espeak import EspeakFallback
fallback = EspeakFallback(british=False, version='1.1')
g2p = en.G2P(version='1.1', trf=False, british=False, fallback=fallback, unk='')
for text in (
    'Have you ever wondered how AI-generated voices work?',
    'OpenAI, ChatGPT, LangChain, RAG, MCP, LLM and API are useful tools.',
):
    ps, _ = g2p(text)
    assert ps and '❓' not in ps, (text, ps)
    print('[Kokoro-English] G2P OK:', text, '=>', ps)
PY

# The running process may have started earlier with temporary eSpeak fallback.
# Restart once so Kokoro loads the official English frontend.
echo '[Kokoro-English] 重启 API 以启用正式英文 G2P'
bash "$PROJECT_DIR/scripts/restart.sh"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
PORT="${PROJECT5_PORT:-8005}"
ADMIN_KEY="${ADMIN_KEY:-}"

READY=0
for _ in {1..180}; do
  RUNTIME="$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/runtime" 2>/dev/null || true)"
  if printf '%s' "$RUNTIME" | grep -q 'misaki-en-g2p+espeak-fallback'; then
    READY=1
    break
  fi
  sleep 1
done
[ "$READY" -eq 1 ] || {
  echo '[Kokoro-English][ERROR] API 重启后没有启用官方 Misaki English G2P';
  tail -n 120 logs/app.log || true;
  exit 1;
}

echo '[Kokoro-English] 真实生成纯英文 + 中英混合 WAV'
[ -n "$ADMIN_KEY" ] || { echo '[Kokoro-English][ERROR] ADMIN_KEY 缺失'; exit 1; }

run_case() {
  local text="$1" label="$2"
  local submit task_id status json err
  submit="$(curl -fsS -X POST "http://127.0.0.1:${PORT}/admin/speech" \
    -H "X-Admin-Key: ${ADMIN_KEY}" -H 'Content-Type: application/json' \
    --data "$(TEXT="$text" "$PY" - <<'PY'
import json, os
print(json.dumps({'input': os.environ['TEXT'], 'engine':'kokoro', 'voice':'zf_001', 'speed':1.0}, ensure_ascii=False))
PY
)")"
  task_id="$(printf '%s' "$submit" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))')"
  [ -n "$task_id" ] || { echo "[Kokoro-English][ERROR] ${label} 未返回 task_id"; exit 1; }
  for _ in {1..300}; do
    json="$(curl -fsS --max-time 3 -H "X-Admin-Key: ${ADMIN_KEY}" "http://127.0.0.1:${PORT}/admin/tasks/${task_id}" 2>/dev/null || true)"
    status="$(printf '%s' "$json" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))' 2>/dev/null || true)"
    if [ "$status" = 'completed' ]; then
      echo "[Kokoro-English] ${label} REAL WAV OK task=${task_id}"
      return 0
    fi
    if [ "$status" = 'failed' ]; then
      err="$(printf '%s' "$json" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("error", ""))' 2>/dev/null || true)"
      echo "[Kokoro-English][ERROR] ${label}: ${err}"
      exit 1
    fi
    sleep 1
  done
  echo "[Kokoro-English][ERROR] ${label} 生成超时"
  exit 1
}

run_case 'Have you ever wondered how AI-generated voices work? Open-source TTS models are becoming surprisingly powerful.' '纯英文'
run_case '今天我们测试 OpenAI、ChatGPT、LangChain、RAG、Agent、MCP、LLM 和 API，然后继续学习。' '中英混合'

echo '[Kokoro-English][OK] 官方英文 G2P + 纯英文 + 中英混合真实生成全部通过'
