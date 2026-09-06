#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p models logs

VOICES_FILE="$PROJECT_DIR/models/voices-v1.1-zh.bin"
VOICES_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/voices-v1.1-zh.bin"
VOICES_BYTES=53815880
TMP_FILE="${VOICES_FILE}.part"

PYTHON_BIN=""
for candidate in python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" >/dev/null 2>&1; then
    PYTHON_BIN="$candidate"
    break
  fi
done
[ -n "$PYTHON_BIN" ] || { echo '[ERROR] 找不到 Python'; exit 1; }

validate_voices() {
  local file="$1"
  VOICES_CHECK_FILE="$file" VOICES_EXPECTED_BYTES="$VOICES_BYTES" "$PYTHON_BIN" - <<'PY'
import os
import sys
import zipfile
from pathlib import Path

path = Path(os.environ['VOICES_CHECK_FILE'])
expected = int(os.environ['VOICES_EXPECTED_BYTES'])
if not path.exists():
    raise SystemExit(10)
if path.stat().st_size != expected:
    print(f'[VOICE-CHECK] size mismatch: {path.stat().st_size} != {expected}')
    raise SystemExit(11)
with path.open('rb') as f:
    if f.read(4) != b'PK\x03\x04':
        print('[VOICE-CHECK] not a valid NPZ/ZIP header')
        raise SystemExit(12)
try:
    with zipfile.ZipFile(path) as zf:
        names = zf.namelist()
        if len(names) != 103:
            print(f'[VOICE-CHECK] voice entries mismatch: {len(names)} != 103')
            raise SystemExit(13)
        required = {'zf_001.npy', 'zm_100.npy'}
        if not required.issubset(set(names)):
            print('[VOICE-CHECK] required voices missing')
            raise SystemExit(14)
        bad = zf.testzip()
        if bad is not None:
            print(f'[VOICE-CHECK] CRC/header failure in {bad}')
            raise SystemExit(15)
except zipfile.BadZipFile as exc:
    print(f'[VOICE-CHECK] bad zip: {exc}')
    raise SystemExit(16)
print(f'[VOICE-CHECK] OK bytes={expected} entries=103')
PY
}

REPAIRED=0
if validate_voices "$VOICES_FILE"; then
  echo '[Project5] 音色包完整，无需重新下载'
else
  echo '[Project5] 检测到 voices-v1.1-zh.bin 已损坏或不是官方完整文件，强制重新下载'
  rm -f "$TMP_FILE"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 12 --retry-all-errors --retry-delay 2 --connect-timeout 20 --speed-time 60 --speed-limit 1024 -o "$TMP_FILE" "$VOICES_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=12 --timeout=30 -O "$TMP_FILE" "$VOICES_URL"
  else
    echo '[ERROR] 缺少 curl/wget'
    exit 1
  fi

  validate_voices "$TMP_FILE"
  mv -f "$TMP_FILE" "$VOICES_FILE"
  REPAIRED=1
  echo '[Project5] 官方 103 音色包已重新下载并通过完整 ZIP/CRC 校验'
fi

if [ "$REPAIRED" -eq 1 ]; then
  # A previous selfcheck is no longer meaningful after replacing a corrupted runtime asset.
  rm -f "$PROJECT_DIR/logs/last-selfcheck.json"
fi

exec bash "$PROJECT_DIR/scripts/bootstrap-runtime.sh"
