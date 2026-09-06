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

restore_transaction() {
  [ -s "$MANIFEST" ] || return 0
  while IFS=$'\t' read -r original backup; do
    [ -n "$original" ] || continue
    [ -f "$backup" ] || continue
    cp -a "$backup" "$original"
  done < "$MANIFEST"
}

# Important: run the editor with set +e so a parser/ambiguity error can restore
# every file already touched in this transaction. Earlier revisions could exit at
# Python failure before rollback code was reached.
set +e
PROJECT5_NGINX_CONF="$CANDIDATE" \
PROJECT5_PUBLIC_PORT="$PUBLIC_PORT" \
PROJECT5_UPSTREAM_PORT="$UPSTREAM_PORT" \
PROJECT5_NGINX_VHOST_DIR="$VHOST_DIR" \
PROJECT5_NGINX_TXN_DIR="$TXN_DIR" \
PROJECT5_NGINX_MANIFEST="$MANIFEST" \
PROJECT5_PUBLIC_HOST_FILE="$PROJECT_DIR/logs/project5-public-host" \
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
vhost_dir = Path(os.environ["PROJECT5_NGINX_VHOST_DIR"]).resolve()
txn_dir = Path(os.environ["PROJECT5_NGINX_TXN_DIR"]).resolve()
manifest = Path(os.environ["PROJECT5_NGINX_MANIFEST"]).resolve()
host_file = Path(os.environ["PROJECT5_PUBLIC_HOST_FILE"]).resolve()

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
server_name_re = re.compile(r"(?m)^[ \t]*server_name[ \t]+([^;\n]+);")


def block_end(text: str, open_index: int) -> int:
    depth = 0
    in_single = in_double = escaped = in_comment = False
    for i in range(open_index, len(text)):
        ch = text[i]
        if in_comment:
            if ch == "\n": in_comment = False
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
        if ch == "{": depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0: return i + 1
    raise RuntimeError("unbalanced nginx braces")


def blocks(text: str, regex: re.Pattern[str]) -> list[tuple[int, int]]:
    out = []
    for m in regex.finditer(text):
        oi = text.find("{", m.start(), m.end())
        if oi >= 0:
            out.append((m.start(), block_end(text, oi)))
    return out


def root_blocks(text: str) -> list[tuple[int, int]]:
    return blocks(text, root_location_re)


def find_target_server(text: str) -> tuple[int, int]:
    found = [(s, e) for s, e in blocks(text, server_re) if listen_re.search(text[s:e])]
    if len(found) != 1:
        raise RuntimeError(f"target server count for port {public_port}: {len(found)}")
    return found[0]


def resolve_include(raw: str, parent: Path) -> list[Path]:
    value = raw.strip().strip("\"'")
    if not value or "$" in value:
        return []
    p = Path(value)
    if not p.is_absolute():
        p = (parent.parent / p).resolve()
    return [Path(x).resolve() for x in glob.glob(str(p)) if Path(x).is_file()]


def direct_includes(text: str, parent: Path) -> list[Path]:
    out: list[Path] = []
    for m in include_re.finditer(text):
        out.extend(resolve_include(m.group(1), parent))
    return out


def recursive_includes(seed: list[Path]) -> list[Path]:
    queue = list(seed)
    seen: set[Path] = set()
    out: list[Path] = []
    while queue and len(seen) < 150:
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


def backup_and_write(path: Path, new_text: str) -> None:
    old = path.read_text(encoding="utf-8")
    if old == new_text:
        return
    backup = txn_dir / f"{len(list(txn_dir.glob('*.bak'))):03d}-{path.name}.bak"
    shutil.copy2(path, backup)
    with manifest.open("a", encoding="utf-8") as fh:
        fh.write(f"{path}\t{backup}\n")
    path.write_text(new_text, encoding="utf-8")
    print(f"[Project5][PROXY] 修改：{path}")


def replace_spans(text: str, spans: list[tuple[int, int]], first_replacement: str | None) -> str:
    if not spans:
        return text
    result = text
    for idx in range(len(spans) - 1, -1, -1):
        a, b = spans[idx]
        replacement = first_replacement if idx == 0 else "\n    # PROJECT5 removed duplicate root location\n"
        result = result[:a] + (replacement or "") + result[b:]
    return result


def safe_site_include(path: Path) -> bool:
    try:
        path.relative_to(vhost_dir)
    except ValueError:
        return False
    p = str(path).replace("\\", "/")
    # BaoTa site-specific reverse-proxy/extension files live under these folders.
    return "/proxy/" in p or "/extension/" in p or main.stem in p


main_text = main.read_text(encoding="utf-8")
ss, se = find_target_server(main_text)
server_text = main_text[ss:se]

# Remember the actual virtual-host name so the deploy verifier can send the same
# Host header as a real browser. Curling 127.0.0.1 without it can hit another
# default vhost and falsely report deployment failure even when the proxy is good.
m = server_name_re.search(server_text)
public_host = "127.0.0.1"
if m:
    names = [x for x in m.group(1).split() if x not in {"_", "localhost"}]
    if names:
        public_host = names[0]
host_file.parent.mkdir(parents=True, exist_ok=True)
host_file.write_text(public_host + "\n", encoding="utf-8")
print(f"[Project5][PROXY] 公网 Host 验证值：{public_host}")

included = recursive_includes(direct_includes(server_text, main))
included_roots: list[tuple[Path, list[tuple[int, int]], str]] = []
for path in included:
    try:
        txt = path.read_text(encoding="utf-8")
    except OSError:
        continue
    roots = root_blocks(txt)
    if roots:
        included_roots.append((path, roots, txt))

# Validate safety before touching anything. A root location from a shared/global
# include is not auto-edited; that would risk another site.
unsafe = [str(path) for path, _, _ in included_roots if not safe_site_include(path)]
if unsafe:
    raise RuntimeError("root location found in shared include; refusing unsafe edit: " + ", ".join(unsafe[:6]))

direct = root_blocks(server_text)
print(f"[Project5][PROXY] 根 location 现状：主配置={len(direct)}，站点 include={sum(len(r) for _, r, _ in included_roots)}")

if direct:
    # Canonical root lives in the main vhost. Replace the first root, remove any
    # duplicate direct roots, and remove site-local included root blocks.
    new_server = replace_spans(server_text, direct, proxy_block)
    backup_and_write(main, main_text[:ss] + new_server + main_text[se:])
    for path, roots, txt in included_roots:
        backup_and_write(path, replace_spans(txt, roots, None))
else:
    total_included = sum(len(r) for _, r, _ in included_roots)
    if total_included:
        # Keep one site-local included root as the canonical root and delete any
        # extras. Prefer a BaoTa proxy include because that is its intended home.
        included_roots.sort(key=lambda item: ("/proxy/" not in str(item[0]).replace("\\", "/"), str(item[0])))
        first_path, first_roots, first_txt = included_roots[0]
        backup_and_write(first_path, replace_spans(first_txt, first_roots, proxy_block))
        for path, roots, txt in included_roots[1:]:
            backup_and_write(path, replace_spans(txt, roots, None))
    else:
        # No root location anywhere: insert exactly one before the target server's
        # closing brace.
        closing = server_text.rfind("}")
        if closing < 0:
            raise RuntimeError("target server closing brace not found")
        new_server = server_text[:closing] + "\n" + proxy_block + server_text[closing:]
        backup_and_write(main, main_text[:ss] + new_server + main_text[se:])
PY
PY_RC=$?
set -e

if [ "$PY_RC" -ne 0 ]; then
  echo "[Project5][PROXY][ERROR] 配置分析/修改失败 rc=${PY_RC}，恢复本次修改"
  restore_transaction
  exit 6
fi

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
