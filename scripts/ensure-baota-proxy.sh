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
  echo "[Project5][PROXY] 主配置已直接指向 http://127.0.0.1:${UPSTREAM_PORT}"
fi

STAMP="$(date '+%Y%m%d-%H%M%S')"
TXN_DIR="$BACKUP_DIR/${STAMP}-$$"
MANIFEST="$TXN_DIR/manifest.tsv"
mkdir -p "$TXN_DIR"

# BaoTa often keeps reverse-proxy `location /` blocks in an included file under
# vhost/nginx/proxy/*.conf instead of in the top-level vhost. The old deploy script
# only inspected the top-level file. When it failed to see the included root
# location it inserted a second `location /`, and `nginx -t` correctly rejected it
# as "duplicate location /". This patcher follows includes belonging to the target
# server block and replaces the real root location at its source.
PROJECT5_NGINX_CONF="$CANDIDATE" \
PROJECT5_PUBLIC_PORT="$PUBLIC_PORT" \
PROJECT5_UPSTREAM_PORT="$UPSTREAM_PORT" \
PROJECT5_NGINX_TXN_DIR="$TXN_DIR" \
PROJECT5_NGINX_MANIFEST="$MANIFEST" \
python3 - <<'PY'
from __future__ import annotations

import glob
import os
import re
import shutil
from pathlib import Path

main = Path(os.environ['PROJECT5_NGINX_CONF']).resolve()
public_port = os.environ['PROJECT5_PUBLIC_PORT']
upstream_port = os.environ['PROJECT5_UPSTREAM_PORT']
txn_dir = Path(os.environ['PROJECT5_NGINX_TXN_DIR']).resolve()
manifest = Path(os.environ['PROJECT5_NGINX_MANIFEST']).resolve()

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

marker_re = re.compile(
    r'^[ \t]*# PROJECT5-AUTO-PROXY-START\s*\n.*?^[ \t]*# PROJECT5-AUTO-PROXY-END\s*\n?',
    re.M | re.S,
)
server_start_re = re.compile(r'(?m)^[ \t]*server\s*\{')
location_root_re = re.compile(r'(?m)^[ \t]*location[ \t]+(?:\^~[ \t]+)?/[ \t]*\{')
include_re = re.compile(r'(?m)^[ \t]*include[ \t]+([^;\n]+);')
listen_re = re.compile(rf'(?m)^[ \t]*listen[ \t]+(?:[^;\n]*:)?{re.escape(public_port)}(?:[ \t;]|$)')


def matching_brace(text: str, open_i: int) -> int:
    depth = 0
    in_single = False
    in_double = False
    escaped = False
    in_comment = False
    for i in range(open_i, len(text)):
        ch = text[i]
        if in_comment:
            if ch == '\n':
                in_comment = False
            continue
        if escaped:
            escaped = False
            continue
        if ch == '\\':
            escaped = True
            continue
        if not in_single and not in_double and ch == '#':
            in_comment = True
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
            continue
        if ch == '"' and not in_single:
            in_double = not in_double
            continue
        if in_single or in_double:
            continue
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return i + 1
    raise RuntimeError('unbalanced nginx braces')


def find_blocks(text: str, start_re: re.Pattern[str]) -> list[tuple[int, int]]:
    blocks: list[tuple[int, int]] = []
    for match in start_re.finditer(text):
        open_i = text.find('{', match.start(), match.end())
        if open_i < 0:
            continue
        try:
            end = matching_brace(text, open_i)
        except RuntimeError:
            continue
        blocks.append((match.start(), end))
    return blocks


def target_server(text: str) -> tuple[int, int]:
    matches: list[tuple[int, int]] = []
    for start, end in find_blocks(text, server_start_re):
        chunk = text[start:end]
        if listen_re.search(chunk):
            matches.append((start, end))
    if len(matches) != 1:
        raise SystemExit(f'Expected exactly one server block listening on {public_port}, found {len(matches)}')
    return matches[0]


def resolve_include(pattern: str, parent: Path) -> list[Path]:
    raw = pattern.strip().strip('"\'')
    if not raw or '$' in raw:
        return []
    p = Path(raw)
    if not p.is_absolute():
        p = (parent.parent / p).resolve()
    return [Path(x).resolve() for x in glob.glob(str(p)) if Path(x).is_file()]


def collect_includes_from_text(text: str, parent: Path) -> list[Path]:
    result: list[Path] = []
    for m in include_re.finditer(text):
        result.extend(resolve_include(m.group(1), parent))
    return result


def walk_includes(seed: list[Path]) -> list[Path]:
    out: list[Path] = []
    seen: set[Path] = set()
    queue = list(seed)
    while queue and len(seen) < 120:
        path = queue.pop(0)
        if path in seen or not path.is_file():
            continue
        seen.add(path)
        out.append(path)
        try:
            text = path.read_text(encoding='utf-8')
        except OSError:
            continue
        queue.extend(collect_includes_from_text(text, path))
    return out


def root_blocks(text: str) -> list[tuple[int, int]]:
    return find_blocks(text, location_root_re)


def backup_and_write(path: Path, new_text: str) -> None:
    old_text = path.read_text(encoding='utf-8')
    if old_text == new_text:
        return
    backup = txn_dir / f'{len(list(txn_dir.glob("*.bak"))):03d}-{path.name}.bak'
    shutil.copy2(path, backup)
    with manifest.open('a', encoding='utf-8') as fh:
        fh.write(f'{path}\t{backup}\n')
    path.write_text(new_text, encoding='utf-8')
    print(f'[Project5][PROXY] 修改来源：{path}')


main_text = main.read_text(encoding='utf-8')
srv_start, srv_end = target_server(main_text)
server_text = main_text[srv_start:srv_end]

# 1) If an earlier successful Project5 marker already exists in the target server,
# replace that exact block idempotently.
marker = marker_re.search(server_text)
if marker:
    abs_start = srv_start + marker.start()
    abs_end = srv_start + marker.end()
    backup_and_write(main, main_text[:abs_start] + PROXY + main_text[abs_end:])
    raise SystemExit(0)

# 2) Prefer an ordinary root location directly inside this server block.
direct_roots = root_blocks(server_text)
if len(direct_roots) == 1:
    ls, le = direct_roots[0]
    backup_and_write(main, main_text[:srv_start + ls] + PROXY + main_text[srv_start + le:])
    raise SystemExit(0)
if len(direct_roots) > 1:
    raise SystemExit(f'Ambiguous: target server already has {len(direct_roots)} direct location / blocks')

# 3) BaoTa commonly puts location / in an included proxy file. Follow only includes
# referenced by the selected server block, recursively, and replace the real source.
seed = collect_includes_from_text(server_text, main)
include_files = walk_includes(seed)
include_roots: list[tuple[Path, int, int, str]] = []
for path in include_files:
    try:
        text = path.read_text(encoding='utf-8')
    except OSError:
        continue
    for ls, le in root_blocks(text):
        include_roots.append((path, ls, le, text))

if len(include_roots) == 1:
    path, ls, le, text = include_roots[0]
    backup_and_write(path, text[:ls] + PROXY + text[le:])
    raise SystemExit(0)
if len(include_roots) > 1:
    sources = ', '.join(str(x[0]) for x in include_roots[:6])
    raise SystemExit(f'Ambiguous: found {len(include_roots)} included location / blocks: {sources}')

# 4) No root route exists anywhere reachable from this server: insert one into the
# selected server block. This is safe because recursive include inspection found no
# competing location / definition.
closing = server_text.rfind('}')
if closing < 0:
    raise SystemExit('Could not find target server closing brace')
new_server = server_text[:closing] + '\n' + PROXY + server_text[closing:]
backup_and_write(main, main_text[:srv_start] + new_server + main_text[srv_end:])
PY

restore_transaction() {
  if [ ! -s "$MANIFEST" ]; then
    return 0
  fi
  while IFS=$'\t' read -r original backup; do
    [ -n "$original" ] || continue
    [ -f "$backup" ] || continue
    cp -a "$backup" "$original"
  done < "$MANIFEST"
}

NGINX_BIN=""
for candidate in /www/server/nginx/sbin/nginx nginx; do
  if [ -x "$candidate" ] || command -v "$candidate" >/dev/null 2>&1; then
    NGINX_BIN="$candidate"
    break
  fi
done

if [ -z "$NGINX_BIN" ]; then
  echo "[Project5][PROXY][ERROR] 找不到 nginx 命令，恢复原配置"
  restore_transaction
  exit 4
fi

if ! "$NGINX_BIN" -t; then
  echo "[Project5][PROXY][ERROR] nginx -t 失败，恢复本次修改"
  restore_transaction
  "$NGINX_BIN" -t || true
  exit 5
fi

"$NGINX_BIN" -s reload
sleep 1

echo "[Project5][PROXY] 已将宝塔入口 ${PUBLIC_PORT} 指向 Project5 ${UPSTREAM_PORT}，并通过 nginx -t"
