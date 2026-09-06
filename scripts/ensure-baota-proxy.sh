#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

UPSTREAM_PORT="${PROJECT5_PORT:-8005}"
PUBLIC_PORT="${PROJECT5_PUBLIC_PORT:-28442}"
VHOST_DIR="${BT_NGINX_VHOST_DIR:-/www/server/panel/vhost/nginx}"
BACKUP_DIR="$PROJECT_DIR/logs/nginx-backups"
mkdir -p "$BACKUP_DIR"

if [ ! -d "$VHOST_DIR" ]; then
  echo "[Project5][PROXY] 未发现宝塔 Nginx vhost 目录：$VHOST_DIR，跳过自动代理修复"
  exit 2
fi

mapfile -t BY_PORT < <(grep -lE "listen[[:space:]]+([^;[:space:]]*:)?${PUBLIC_PORT}([[:space:]]|;)" "$VHOST_DIR"/*.conf 2>/dev/null || true)
mapfile -t BY_ROOT < <(grep -lF "$PROJECT_DIR" "$VHOST_DIR"/*.conf 2>/dev/null || true)

CANDIDATE=""
if [ "${#BY_PORT[@]}" -eq 1 ]; then
  CANDIDATE="${BY_PORT[0]}"
elif [ "${#BY_PORT[@]}" -gt 1 ]; then
  for file in "${BY_PORT[@]}"; do
    if grep -Fq "$PROJECT_DIR" "$file"; then CANDIDATE="$file"; break; fi
  done
elif [ "${#BY_ROOT[@]}" -eq 1 ]; then
  CANDIDATE="${BY_ROOT[0]}"
fi

if [ -z "$CANDIDATE" ]; then
  echo "[Project5][PROXY][ERROR] 无法唯一定位宝塔站点配置。public_port=${PUBLIC_PORT} project=${PROJECT_DIR}"
  echo "[Project5][PROXY] 端口匹配数=${#BY_PORT[@]} 项目目录匹配数=${#BY_ROOT[@]}"
  exit 3
fi

echo "[Project5][PROXY] 站点配置：$CANDIDATE"

if grep -Eq "proxy_pass[[:space:]]+http://127\.0\.0\.1:${UPSTREAM_PORT}([/;[:space:]]|$)" "$CANDIDATE"; then
  echo "[Project5][PROXY] 已指向 http://127.0.0.1:${UPSTREAM_PORT}，无需修改"
  exit 0
fi

STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP="$BACKUP_DIR/$(basename "$CANDIDATE").${STAMP}.bak"
cp -a "$CANDIDATE" "$BACKUP"

PROJECT5_NGINX_CONF="$CANDIDATE" PROJECT5_PUBLIC_PORT="$PUBLIC_PORT" PROJECT5_UPSTREAM_PORT="$UPSTREAM_PORT" python3 - <<'PY'
from pathlib import Path
import os, re

path = Path(os.environ['PROJECT5_NGINX_CONF'])
public_port = os.environ['PROJECT5_PUBLIC_PORT']
upstream_port = os.environ['PROJECT5_UPSTREAM_PORT']
text = path.read_text(encoding='utf-8')

PROXY = f'''    # PROJECT5-AUTO-PROXY-START
    location / {{
        proxy_pass http://127.0.0.1:{upstream_port};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 10s;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_buffering off;
    }}
    # PROJECT5-AUTO-PROXY-END
'''

marker = re.compile(r'\s*# PROJECT5-AUTO-PROXY-START.*?# PROJECT5-AUTO-PROXY-END\s*', re.S)
if marker.search(text):
    path.write_text(marker.sub('\n' + PROXY, text, count=1), encoding='utf-8')
    raise SystemExit(0)

# Basic brace scanner. BaoTa-generated vhost files are regular Nginx text; this
# deliberately modifies only the server block that listens on PROJECT5_PUBLIC_PORT.
def blocks(src: str, keyword: str):
    out = []
    for m in re.finditer(rf'\b{re.escape(keyword)}\b[^{{]*{{', src):
        start = m.start()
        open_i = src.find('{', m.start(), m.end())
        depth = 0
        in_s = in_d = False
        esc = False
        for i in range(open_i, len(src)):
            ch = src[i]
            if esc:
                esc = False; continue
            if ch == '\\':
                esc = True; continue
            if ch == "'" and not in_d: in_s = not in_s; continue
            if ch == '"' and not in_s: in_d = not in_d; continue
            if in_s or in_d: continue
            if ch == '{': depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    out.append((start, open_i, i + 1))
                    break
    return out

server = None
listen_re = re.compile(rf'\blisten\s+(?:[^;\n]*:)?{re.escape(public_port)}(?:\s|;|\b)')
for s, o, e in blocks(text, 'server'):
    chunk = text[s:e]
    if listen_re.search(chunk):
        server = (s, o, e)
        break

if server is None:
    raise SystemExit(f'No server block listening on {public_port}')

s, o, e = server
chunk = text[s:e]

# Prefer replacing a root location in the selected server block. If it does not
# exist, insert our proxy location before the server closing brace.
location_matches = []
for lm in re.finditer(r'\blocation\s+(?:\^~\s+)?/\s*{', chunk):
    open_rel = chunk.find('{', lm.start(), lm.end())
    depth = 0
    for i in range(open_rel, len(chunk)):
        if chunk[i] == '{': depth += 1
        elif chunk[i] == '}':
            depth -= 1
            if depth == 0:
                location_matches.append((lm.start(), i + 1))
                break

if location_matches:
    ls, le = location_matches[0]
    new_chunk = chunk[:ls] + PROXY + chunk[le:]
else:
    closing = chunk.rfind('}')
    new_chunk = chunk[:closing] + '\n' + PROXY + chunk[closing:]

path.write_text(text[:s] + new_chunk + text[e:], encoding='utf-8')
PY

NGINX_BIN=""
for candidate in /www/server/nginx/sbin/nginx nginx; do
  if [ -x "$candidate" ] || command -v "$candidate" >/dev/null 2>&1; then NGINX_BIN="$candidate"; break; fi
done

if [ -z "$NGINX_BIN" ]; then
  echo "[Project5][PROXY][ERROR] 找不到 nginx 命令，恢复原配置"
  cp -a "$BACKUP" "$CANDIDATE"
  exit 4
fi

if ! "$NGINX_BIN" -t; then
  echo "[Project5][PROXY][ERROR] nginx -t 失败，恢复原配置"
  cp -a "$BACKUP" "$CANDIDATE"
  "$NGINX_BIN" -t || true
  exit 5
fi

"$NGINX_BIN" -s reload
sleep 1

echo "[Project5][PROXY] 已将宝塔入口 ${PUBLIC_PORT} 指向 Project5 ${UPSTREAM_PORT}，并通过 nginx -t"
