#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
mkdir -p logs data/audio models

# ---------------------------------------------------------------------------
# 0) Always deploy the real latest origin/main, even if BaoTa triggered this
#    script from an older webhook commit. Multiple webhook events are serialized
#    so an old event can never overwrite a newer deployment.
# ---------------------------------------------------------------------------
if [ "${PROJECT5_DEPLOY_LOCK_HELD:-0}" != "1" ]; then
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$PROJECT_DIR/logs/auto-deploy.lock"
    if ! flock -w 300 9; then
      echo '[SYNC][ERROR] 300 秒内没有拿到部署锁，放弃本次重复 Webhook'
      exit 75
    fi
    export PROJECT5_DEPLOY_LOCK_HELD=1
  fi
fi

# Absorb a burst of GitHub commits/webhooks, then always ask origin/main what the
# newest commit is. This fixes the old behaviour where auto-deploy trusted the
# commit that BaoTa happened to have checked out before running this script.
if [ "${PROJECT5_DEPLOY_REEXEC:-0}" != "1" ]; then
  sleep "${PROJECT5_DEPLOY_DEBOUNCE_SECONDS:-2}"
fi

git config --global --add safe.directory "$PROJECT_DIR" >/dev/null 2>&1 || true
DEPLOY_BRANCH="${PROJECT5_DEPLOY_BRANCH:-main}"
LOCAL_BEFORE="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
echo "[SYNC] 本地开始 commit=${LOCAL_BEFORE}"
echo "[SYNC] 强制查询 origin/${DEPLOY_BRANCH} 最新提交"

FETCH_OK=0
for attempt in 1 2 3 4; do
  if git fetch --prune origin "+refs/heads/${DEPLOY_BRANCH}:refs/remotes/origin/${DEPLOY_BRANCH}"; then
    FETCH_OK=1
    break
  fi
  echo "[SYNC] git fetch 第 ${attempt} 次失败，稍后重试"
  sleep $((attempt * 2))
done
if [ "$FETCH_OK" -ne 1 ]; then
  echo '[SYNC][ERROR] 无法从 GitHub 获取 origin/main；为避免部署旧代码，本次直接失败，旧服务保持不动'
  exit 20
fi

REMOTE_COMMIT="$(git rev-parse "origin/${DEPLOY_BRANCH}" 2>/dev/null || true)"
[ -n "$REMOTE_COMMIT" ] || { echo '[SYNC][ERROR] origin/main 没有可解析的 commit'; exit 21; }
echo "[SYNC] GitHub 最新 commit=${REMOTE_COMMIT}"

if [ "$LOCAL_BEFORE" != "$REMOTE_COMMIT" ]; then
  echo "[SYNC] 服务器落后：${LOCAL_BEFORE} -> ${REMOTE_COMMIT}"
  git reset --hard "$REMOTE_COMMIT"
  # We are still executing the old script body that was loaded before reset.
  # Re-exec the just-downloaded version once so the deployment logic itself is
  # also guaranteed to be the newest version.
  export PROJECT5_DEPLOY_REEXEC=1
  echo '[SYNC] 已同步最新代码，重新进入最新 auto-deploy.sh'
  exec bash "$PROJECT_DIR/scripts/auto-deploy.sh"
fi

echo '[SYNC][OK] 服务器源码已经与 origin/main 最新提交一致'

printf '%s\n' '===================================================='
printf '%s\n' ' Project5 · BaoTa Verified Deploy'
printf '%s\n' ' latest-main -> port -> app -> nginx/public -> commit'
printf '%s\n' '===================================================='

PYTHON_BIN=""
for candidate in python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
    PYTHON_BIN="$candidate"
    break
  fi
done
[ -n "$PYTHON_BIN" ] || { echo '[ERROR] 需要 Python 3.10+'; exit 1; }

CURRENT_COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
if [ "$CURRENT_COMMIT" != "$REMOTE_COMMIT" ]; then
  echo "[1/7][ERROR] 同步后仍不一致：local=${CURRENT_COMMIT} remote=${REMOTE_COMMIT}"
  exit 22
fi
echo "[1/7] Git 已同步最新 main：${CURRENT_COMMIT}"

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
PROJECT5_PUBLIC_PORT=28442
ADMIN_KEY=${ADMIN_KEY}
MAX_TEXT_LENGTH=5000
EOF
fi
set_env_value PROJECT5_PORT "${PROJECT5_PORT:-8005}"
set_env_value PROJECT5_PUBLIC_PORT "${PROJECT5_PUBLIC_PORT:-28442}"
set_env_value KOKORO_THREADS 8
set_env_value KOKORO_ONNX_MODEL "${PROJECT_DIR}/models/kokoro-v1.1-zh.onnx"
set_env_value KOKORO_ONNX_VOICES "${PROJECT_DIR}/models/voices-v1.1-zh.bin"
set_env_value KOKORO_ONNX_CONFIG "${PROJECT_DIR}/models/config.json"
chmod 600 .env
set -a
# shellcheck disable=SC1091
source .env
set +a
PORT="${PROJECT5_PORT:-8005}"
PUBLIC_PORT="${PROJECT5_PUBLIC_PORT:-28442}"

echo "[2/7] Project5 内部端口=${PORT} · 宝塔入口端口=${PUBLIC_PORT}"

# Remove stale one-off workers from older revisions. They must never hold the
# bootstrap lock or keep restarting an older process while this deploy publishes.
pkill -f "$PROJECT_DIR/scripts/setup-kokoro-english.sh" >/dev/null 2>&1 || true
pkill -f 'scripts/build-voice-previews.py' >/dev/null 2>&1 || true
pkill -f 'scripts/setup-melo.sh' >/dev/null 2>&1 || true
bash "$PROJECT_DIR/scripts/stop-melo.sh" >/dev/null 2>&1 || true

local_is_current() {
  local page version library
  page="$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/?_=${CURRENT_COMMIT}" 2>/dev/null || true)"
  version="$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/deploy-version?_=${CURRENT_COMMIT}" 2>/dev/null || true)"
  library="$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/static/voice-library.js?_=${CURRENT_COMMIT}" 2>/dev/null || true)"
  printf '%s' "$page" | grep -q 'Kokoro 本地试听' \
    && printf '%s' "$page" | grep -q 'Edge 在线试听' \
    && printf '%s' "$library" | grep -q '音色库 / 固定试听表' \
    && printf '%s' "$library" | grep -q '一键生成全部试听' \
    && printf '%s' "$library" | grep -q '24小时自动清理' \
    && printf '%s' "$version" | grep -q "$CURRENT_COMMIT" \
    && printf '%s' "$version" | grep -q 'voice-library-retention-v1'
}

NEEDS_REPAIR=0
if [ ! -x .venv/bin/python ]; then NEEDS_REPAIR=1; fi
if [ ! -s models/kokoro-v1.1-zh.onnx ] || [ "$(stat -c%s models/kokoro-v1.1-zh.onnx 2>/dev/null || echo 0)" -lt 300000000 ]; then NEEDS_REPAIR=1; fi
if [ ! -s models/voices-v1.1-zh.bin ] || [ "$(stat -c%s models/voices-v1.1-zh.bin 2>/dev/null || echo 0)" -lt 53000000 ]; then NEEDS_REPAIR=1; fi
if [ ! -s models/config.json ]; then NEEDS_REPAIR=1; fi
if [ -x .venv/bin/python ] && ! .venv/bin/python - <<'PY' >/dev/null 2>&1
import edge_tts, kokoro_onnx, onnxruntime, soundfile
from misaki.zh import ZHG2P
PY
then
  NEEDS_REPAIR=1
fi

FAST_OK=0
if [ -x .venv/bin/python ]; then
  echo '[3/7] 强制停止真正占用 Project5 端口的旧进程，然后启动最新 main'
  if bash "$PROJECT_DIR/scripts/restart.sh" && local_is_current; then
    FAST_OK=1
    echo '[3/7] [OK] localhost 新进程已经是最新 main，并包含音色库/24h功能'
  else
    echo '[3/7] 快速启动失败：转入运行环境修复'
    NEEDS_REPAIR=1
  fi
else
  echo '[3/7] .venv 尚不存在：需要先创建运行环境'
fi

start_repair_worker() {
  local log_file="$PROJECT_DIR/logs/bootstrap-runtime.log"
  local worker="$PROJECT_DIR/scripts/repair-runtime-assets.sh"
  if [ -f "$PROJECT_DIR/logs/deploy-worker.pid" ]; then
    old="$(cat "$PROJECT_DIR/logs/deploy-worker.pid" 2>/dev/null || true)"
    if [[ "$old" =~ ^[0-9]+$ ]] && kill -0 "$old" 2>/dev/null; then
      echo "[Project5] 已有环境修复 worker=${old}，不重复启动"
      return 0
    fi
  fi
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid bash "$worker" >> "$log_file" 2>&1 < /dev/null &
  else
    nohup bash "$worker" >> "$log_file" 2>&1 < /dev/null &
  fi
  worker_pid=$!
  disown "$worker_pid" 2>/dev/null || true
  printf '%s\n' "$worker_pid" > "$PROJECT_DIR/logs/deploy-worker.pid"
  echo "[Project5] 环境修复 worker=${worker_pid} 已启动"
}

if [ "$FAST_OK" -ne 1 ]; then
  start_repair_worker
  echo '[4/7] 等待修复 worker 首次把当前前端启动（最多 180 秒）'
  for _ in {1..180}; do
    if local_is_current; then FAST_OK=1; break; fi
    sleep 1
  done
  if [ "$FAST_OK" -ne 1 ]; then
    echo '[4/7][ERROR] 180 秒内 localhost 仍不是当前版本。最近日志：'
    tail -n 160 "$PROJECT_DIR/logs/bootstrap-runtime.log" || true
    exit 1
  fi
  echo '[4/7] [OK] 修复后 localhost 当前版本已上线'
else
  echo '[4/7] 不需要等待运行环境修复'
fi

if [ "$NEEDS_REPAIR" -eq 1 ]; then
  start_repair_worker
  echo '[5/7] 运行环境/模型补全在后台继续，不阻塞前端发布'
else
  echo '[5/7] 当前运行环境完整，不启动重型重复自检 worker'
fi

echo '[6/7] 检查并修复宝塔 Nginx 对外入口'
PROXY_RC=0
bash "$PROJECT_DIR/scripts/ensure-baota-proxy.sh" || PROXY_RC=$?
if [ "$PROXY_RC" -ne 0 ]; then
  echo "[6/7][ERROR] 宝塔 Nginx 入口修复失败 rc=${PROXY_RC}。localhost 已是新版，但公网入口仍可能显示旧页面。"
  exit 1
fi

public_is_current() {
  local page version
  page="$(curl -fsS --max-time 4 "http://127.0.0.1:${PUBLIC_PORT}/?_=${CURRENT_COMMIT}" 2>/dev/null || true)"
  version="$(curl -fsS --max-time 4 "http://127.0.0.1:${PUBLIC_PORT}/deploy-version?_=${CURRENT_COMMIT}" 2>/dev/null || true)"
  printf '%s' "$page" | grep -q 'Kokoro 本地试听' \
    && printf '%s' "$version" | grep -q "$CURRENT_COMMIT" \
    && printf '%s' "$version" | grep -q 'voice-library-retention-v1'
}

for _ in {1..20}; do
  if public_is_current; then
    echo "[7/7] [OK] 真正部署成功：origin/main、Git HEAD、${PORT} 新进程、宝塔/Nginx ${PUBLIC_PORT} 公网入口全部一致 ${CURRENT_COMMIT}"
    exit 0
  fi
  sleep 1
done

echo "[7/7][ERROR] localhost:${PORT} 已是新版，但宝塔入口 ${PUBLIC_PORT} 仍没有返回当前 commit。"
echo '[Project5] 这次不会再把“代码没同步 / 内部服务成功”误报成“公网部署成功”。'
exit 1
