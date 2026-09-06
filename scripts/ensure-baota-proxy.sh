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
  echo "[Project5][PROXY][ERROR] 未发现宝塔 Nginx vhost 目录：$VHOST_DIR"
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
  echo "[Project5][PROXY] 端口匹配=${#BY_PORT[@]}，目录匹配=${#BY_ROOT[@]}"
  exit 3
fi

echo "[Project5][PROXY] 站点配置：$CANDIDATE"

STAMP="$(date '+%Y%m%d-%H%M%S')"
TXN_DIR="$BACKUP_DIR/${STAMP}-$$"
MANIFEST="$TXN_DIR/manifest.tsv"
mkdir -p "$TXN_DIR"

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

main = Path(os.environ["PROJECT5_NGINX_CONF"]).resolve()
public_port = os.environ["PROJECT5_PUBLIC_PORT"]
upstream_port = os.environ["PROJECT5_UPSTREAM_PORT"]
txn_dir = Path(os.environ["PROJECT5_NGINX_TXN_DIR"]).resolve()
manifest = Path(os.environ["PROJECT5_NGINX_MANIFEST"]).resolve()

# Keep the Project5 markers INSIDE the existing root location. Earlier revisions
# could find a marker inside an already-valid `location / { ... }` block and then
# replace only the marker region with a SECOND full `location /` block. That is the
# exact shape that produces: nginx: [emerg] duplicate location "/".
proxy_block = f'''    location / {{
        # PROJECT5-AUTO-PROXY-START
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
        # PROJECT5-AUTO-PROXY-END
    }}
'''

server_re = re.compile(r"(?m)^[ \t]*server\s*\{")
root_location_re = re.compile(r"(?m)^[ \t]*location[ \t]+(?:\^~[ \t]+)?/[ \t]*\{")
include_re = re.compile(r"(?m)^[ \t]*include[ \t]+([^;\n]+);")
listen_re = re.compile(rf"(?m)^[ \t]*listen[ \t]+(?:[^;\n]*:)?{re.escape(public_port)}(?:[ \t;]|$)")


def block_end(text: str, open_index: int) -> int:
    depth = 0
    in_single = False
    in_double = False
    escaped = False
    in_comment = False
    for i in range(open_index, len(text)):
        ch = text[i]
        if in_comment:
            if ch == "\n":
                in_comment = False
            continue
        if escaped:
            escaped = False
            continue
        if ch == "\\":
            escaped = True
            continue
        if not in_single and not in_double and ch == "#":
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
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i + 1
    raise RuntimeError("unbalanced nginx braces")


def blocks(text: str, regex: re.Pattern[str]) -> list[tuple[int, int]]:
    result = []
    for m in regex.finditer(text):
        open_index = text.find("{", m.start(), m.end())
        if open_index < 0:
            continue
        result.append((m.start(), block_end(text, open_index)))
    return result


def find_target_server(text: str) -> tuple[int, int]:
    found = []
    for start, end in blocks(text, server_re):
        if listen_re.search(text[start:end]):
            found.append((start, end))
    if len(found) != 1:
        raise SystemExit(f"target server count for port {public_port}: {len(found)}")
    return found[0]


def root_blocks(text: str) -> list[tuple[int, int]]:
    return blocks(text, root_location_re)


def resolve_include(raw: str, parent: Path) -> list[Path]:
    value = raw.strip().strip("\"'")
    if not value or "$" in value:
        return []
    p = Path(value)
    if not p.is_absolute():
        p = (parent.parent / p).resolve()
    return [Path(x).resolve() for x in glob.glob(str(p)) if Path(x).is_file()]


def direct_includes(text: str, parent: Path) -> list[Path]:
    out = []
    for m in include_re.finditer(text):
        out.extend(resolve_include(m.group(1), parent))
    return out


def recursive_includes(seed: list[Path]) -> list[Path]:
    queue = list(seed)
    seen: set[Path] = set()
    out: list[Path] = []
    while queue and len(seen) < 120:
        path = queue.pop(0)
        if path in seen or not path.is_file():
            continue
        seen.add(path)
        out.append(path)
        try:
            queue.extend(direct_includes(path.read_text(encoding="utf-8"), path))
        except OSError:
            pass
    return out


def write_with_backup(path: Path, new_text: str) -> None:
    old_text = path.read_text(encoding="utf-8")
    if old_text == new_text:
        return
    backup = txn_dir / f"{len(list(txn_dir.glob('*.bak'))):03d}-{path.name}.bak"
    shutil.copy2(path, backup)
    with manifest.open("a", encoding="utf-8") as fh:
        fh.write(f"{path}\t{backup}\n")
    path.write_text(new_text, encoding="utf-8")
    print(f"[Project5][PROXY] 原位改写已有 location /：{path}")


main_text = main.read_text(encoding="utf-8")
server_start, server_end = find_target_server(main_text)
server_text = main_text[server_start:server_end]

# IMPORTANT: always replace an EXISTING `location /` block as a whole. Do not
# special-case Project5 markers before locating the root block; markers may live
# inside that root block on existing BaoTa sites.
direct_roots = root_blocks(server_text)
if len(direct_roots) == 1:
    a, b = direct_roots[0]
    write_with_backup(main, main_text[:server_start + a] + proxy_block + main_text[server_start + b:])
    raise SystemExit(0)
if len(direct_roots) > 1:
    raise SystemExit(f"ambiguous direct location / count: {len(direct_roots)}")

# BaoTa reverse-proxy sites often put location / in an included proxy/*.conf file.
# Follow includes from THIS server block and modify that existing root location in
# place instead of inserting a second root location into the top-level vhost.
included = recursive_includes(direct_includes(server_text, main))
roots = []
for path in included:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        continue
    for a, b in root_blocks(text):
        roots.append((path, a, b, text))

if len(roots) == 1:
    path, a, b, text = roots[0]
    write_with_backup(path, text[:a] + proxy_block + text[b:])
    raise SystemExit(0)
if len(roots) > 1:
    sources = ", ".join(str(x[0]) for x in roots[:8])
    raise SystemExit(f"ambiguous included location / count: {len(roots)} sources={sources}")

# No direct or included location / exists. Only now is it safe to insert one.
closing = server_text.rfind("}")
if closing < 0:
    raise SystemExit("target server closing brace not found")
new_server = server_text[:closing] + "\n" + proxy_block + server_text[closing:]
write_with_backup(main, main_text[:server_start] + new_server + main_text[server_end:])
PY

restore_transaction() {
  [ -s "$MANIFEST" ] || return 0
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

echo "[Project5][PROXY] 已安全将宝塔入口 ${PUBLIC_PORT} 指向 Project5 ${UPSTREAM_PORT}，nginx -t 已通过"
