#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p logs models/melo-cache .runtime

exec 8>"$PROJECT_DIR/logs/melo-setup.lock"
if command -v flock >/dev/null 2>&1; then
  flock 8
fi

PYTHON_BIN=""
for candidate in python3.10 python3.9 python3.11; do
  if command -v "$candidate" >/dev/null 2>&1; then
    if "$candidate" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if (3, 9) <= sys.version_info[:2] <= (3, 11) else 1)
PY
    then
      PYTHON_BIN="$candidate"
      break
    fi
  fi
done
[ -n "$PYTHON_BIN" ] || { echo '[MeloTTS][ERROR] 需要 Python 3.9~3.11，当前未找到兼容版本'; exit 1; }
echo "[MeloTTS] Python: $($PYTHON_BIN --version)"

RUNTIME_DIR="$PROJECT_DIR/.runtime/MeloTTS"
VENV="$PROJECT_DIR/.venv-melo"

if [ ! -d "$RUNTIME_DIR/.git" ]; then
  echo '[MeloTTS] 获取官方 myshell-ai/MeloTTS'
  rm -rf "$RUNTIME_DIR"
  git clone --depth 1 https://github.com/myshell-ai/MeloTTS.git "$RUNTIME_DIR"
else
  echo '[MeloTTS] 更新官方运行时代码'
  git -C "$RUNTIME_DIR" fetch --depth 1 origin main
  git -C "$RUNTIME_DIR" reset --hard origin/main
fi

if [ ! -x "$VENV/bin/python" ]; then
  echo '[MeloTTS] 创建独立 .venv-melo，避免和 Kokoro/Edge 依赖冲突'
  "$PYTHON_BIN" -m venv "$VENV"
fi

"$VENV/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true
# MeloTTS pins librosa 0.9.1, which still imports pkg_resources. New setuptools
# releases removed that legacy module, so keep a compatible setuptools release.
"$VENV/bin/python" -m pip install -q --upgrade pip wheel 'setuptools==80.9.0'

REQ_HASH="$(sha256sum "$RUNTIME_DIR/requirements.txt" | awk '{print $1}')-project5-v4-torch231cpu-setuptools809"
OLD_HASH="$(cat "$PROJECT_DIR/.melo-requirements.sha256" 2>/dev/null || true)"
if [ "$REQ_HASH" != "$OLD_HASH" ] || ! "$VENV/bin/python" - <<PY >/dev/null 2>&1
import sys
sys.path.insert(0, r'$RUNTIME_DIR')
import pkg_resources
import torch, torchaudio
from melo.api import TTS
assert '+cpu' in torch.__version__ or not torch.cuda.is_available()
print(torch.__version__)
PY
then
  echo '[MeloTTS] 安装固定 CPU 版 PyTorch，避免无 GPU 服务器误装 CUDA 依赖'
  "$VENV/bin/python" -m pip install \
    'torch==2.3.1+cpu' 'torchaudio==2.3.1+cpu' \
    --extra-index-url https://download.pytorch.org/whl/cpu

  FILTERED="$PROJECT_DIR/.runtime/melo-requirements-project5.txt"
  grep -vE '^(torch|torchaudio|gradio|tensorboard)([<=> ].*)?$' "$RUNTIME_DIR/requirements.txt" > "$FILTERED"
  {
    echo 'numpy==1.23.5'
    echo 'scipy==1.10.1'
    echo 'huggingface-hub<1.0'
  } >> "$FILTERED"
  "$VENV/bin/python" -m pip install -r "$FILTERED"
  # Re-assert setuptools after dependency installation in case another package moved it.
  "$VENV/bin/python" -m pip install -q 'setuptools==80.9.0'
  echo "$REQ_HASH" > "$PROJECT_DIR/.melo-requirements.sha256"
fi

export PYTHONPATH="$RUNTIME_DIR${PYTHONPATH:+:$PYTHONPATH}"
export HF_HOME="$PROJECT_DIR/models/melo-cache"
export TRANSFORMERS_CACHE="$PROJECT_DIR/models/melo-cache/transformers"
export TOKENIZERS_PARALLELISM=false

"$VENV/bin/python" - <<'PY'
import pkg_resources
import torch
from melo.api import TTS
print('[MeloTTS] Python API import OK, torch=', torch.__version__)
PY

bash "$PROJECT_DIR/scripts/stop-melo.sh" || true
bash "$PROJECT_DIR/scripts/start-melo.sh"

echo '[MeloTTS] runtime installed and local service started'
