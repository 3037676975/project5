#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

if [ ! -x .venv/bin/python ]; then
  echo "[FAIL] .venv 不存在，请先完成部署。"
  exit 1
fi

printf '\n==============================================\n'
printf ' Project5 CPU TTS Benchmark\n'
printf '==============================================\n'

if command -v lscpu >/dev/null 2>&1; then
  lscpu | grep -E 'Model name|CPU\(s\)|Thread|Core|Socket|MHz|Flags' | head -n 10 || true
fi
printf '\n'

.venv/bin/python - <<'PY'
from pathlib import Path
import os
import time

from app.tts import engine

text = "欢迎来到人工智能技术分享频道，今天我们测试中文语音生成速度。"
print(f"text_chars={len(text)} cpu_count={os.cpu_count()} backend={engine.backend} threads={engine.threads}")
print("等待模型完成预热……")
engine.load()
print(f"load_metrics={engine.load_metrics}")

for i in range(1, 4):
    path = Path(f"data/audio/benchmark_{i}.wav")
    started = time.perf_counter()
    duration = engine.generate(text, "zf_001", 1.0, path)
    elapsed = time.perf_counter() - started
    print(
        f"RUN {i}: elapsed={elapsed:.3f}s audio={duration:.3f}s "
        f"rtf={elapsed / duration:.3f} metrics={engine.last_metrics}"
    )

print("\n判断：重点看 RUN 2 / RUN 3。RTF < 1 表示快于实时；RTF 约 0.5 表示生成 10 秒语音约需 5 秒。")
PY
