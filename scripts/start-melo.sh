#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p logs models/melo-cache data/audio

PORT="${MELO_PORT:-8016}"
PID_FILE="$PROJECT_DIR/logs/melo.pid"
VENV="$PROJECT_DIR/.venv-melo"
RUNTIME="$PROJECT_DIR/.runtime/MeloTTS"

[ -x "$VENV/bin/python" ] || { echo '[MeloTTS] .venv-melo 不存在，等待 setup-melo.sh 安装'; exit 1; }
[ -f "$RUNTIME/melo/api.py" ] || { echo '[MeloTTS] 官方运行时代码不存在，等待 setup-melo.sh 安装'; exit 1; }

if curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
  echo "[MeloTTS] 已运行 port=${PORT}"
  exit 0
fi

export PYTHONPATH="$RUNTIME${PYTHONPATH:+:$PYTHONPATH}"
export HF_HOME="$PROJECT_DIR/models/melo-cache"
export TRANSFORMERS_CACHE="$PROJECT_DIR/models/melo-cache/transformers"
export TOKENIZERS_PARALLELISM=false
export MELO_THREADS="${MELO_THREADS:-4}"

nohup "$VENV/bin/python" "$PROJECT_DIR/scripts/melo_worker.py" --host 127.0.0.1 --port "$PORT" >> "$PROJECT_DIR/logs/melo.log" 2>&1 < /dev/null &
PID=$!
echo "$PID" > "$PID_FILE"

for _ in {1..45}; do
  if curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "[MeloTTS] service ready http://127.0.0.1:${PORT} PID=${PID}"
    exit 0
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    break
  fi
  sleep 1
done

echo '[MeloTTS][ERROR] 本地服务启动失败'
tail -n 100 "$PROJECT_DIR/logs/melo.log" || true
exit 1
