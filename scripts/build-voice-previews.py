#!/usr/bin/env python3
from __future__ import annotations

import fcntl
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
os.chdir(ROOT)
os.environ["KOKORO_THREADS"] = os.getenv("PREVIEW_KOKORO_THREADS", "2")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

PREVIEW_TEXT = (
    "嗨，今天聊点轻松的。I really like simple tools that just work. "
    "最近我在用 ChatGPT 和 LangChain 做 AI 小工具，and it feels pretty useful. "
    "好，我们继续吧。"
)
PREVIEW_ROOT = ROOT / "app" / "static" / "previews"
MANIFEST = PREVIEW_ROOT / "manifest.json"
LOG_DIR = ROOT / "logs"
LOCK_PATH = LOG_DIR / "voice-preview.lock"

PREVIEW_ROOT.mkdir(parents=True, exist_ok=True)
LOG_DIR.mkdir(parents=True, exist_ok=True)
lock_handle = LOCK_PATH.open("w")
try:
    fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    print("[Preview] another preview builder is already running", flush=True)
    raise SystemExit(0)


def wait_for_official_english(timeout_seconds: int = 1800) -> None:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        try:
            import spacy
            import torch  # noqa: F401
            import transformers  # noqa: F401
            from misaki import en  # noqa: F401

            if spacy.util.is_package("en_core_web_sm"):
                print("[Preview] official Misaki English frontend is ready", flush=True)
                return
        except Exception:
            pass
        print("[Preview] waiting for Kokoro English frontend...", flush=True)
        time.sleep(10)
    raise RuntimeError("official Kokoro English frontend was not ready within 30 minutes")


def load_manifest() -> dict:
    if MANIFEST.exists():
        try:
            data = json.loads(MANIFEST.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return data
        except Exception:
            pass
    return {"text": PREVIEW_TEXT, "kokoro": {}, "edge": {}}


def save_manifest(data: dict) -> None:
    data["text"] = PREVIEW_TEXT
    data["updated_at"] = datetime.now().isoformat(timespec="seconds")
    tmp = MANIFEST.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(MANIFEST)


def valid_file(path: Path, engine: str) -> bool:
    if not path.exists():
        return False
    return path.stat().st_size > (512 if engine == "edge" else 44)


wait_for_official_english()
from app.dual_tts import audio_extension, generate, voice_list  # noqa: E402

manifest = load_manifest()
rebuild = os.getenv("PREVIEW_REBUILD", "0") == "1"

for engine in ("kokoro", "edge"):
    engine_dir = PREVIEW_ROOT / engine
    engine_dir.mkdir(parents=True, exist_ok=True)
    items = voice_list(engine)
    print(f"[Preview] building {engine} previews: {len(items)} voices", flush=True)
    ready_map = manifest.setdefault(engine, {})

    for index, item in enumerate(items, start=1):
        voice = item["id"]
        ext = audio_extension(engine)
        target = engine_dir / f"{voice}{ext}"
        url = f"/static/previews/{engine}/{target.name}"

        if not rebuild and valid_file(target, engine):
            ready_map[voice] = url
            save_manifest(manifest)
            print(f"[Preview] {engine} {index}/{len(items)} cached {voice}", flush=True)
            continue

        try:
            target.unlink(missing_ok=True)
            started = time.perf_counter()
            duration = generate(engine, PREVIEW_TEXT, voice, 1.0, target)
            if not valid_file(target, engine):
                raise RuntimeError("preview output is missing or empty")
            ready_map[voice] = url
            save_manifest(manifest)
            print(
                f"[Preview] {engine} {index}/{len(items)} OK {voice} "
                f"duration={duration:.2f}s elapsed={time.perf_counter()-started:.2f}s",
                flush=True,
            )
        except Exception as exc:
            target.unlink(missing_ok=True)
            ready_map.pop(voice, None)
            save_manifest(manifest)
            print(f"[Preview][WARN] {engine} {voice}: {type(exc).__name__}: {exc}", flush=True)

save_manifest(manifest)
print(
    f"[Preview][OK] cached kokoro={len(manifest.get('kokoro', {}))} "
    f"edge={len(manifest.get('edge', {}))}",
    flush=True,
)
