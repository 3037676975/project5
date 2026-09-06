from __future__ import annotations

import asyncio
import hashlib
import json
import secrets
import threading
from datetime import datetime
from pathlib import Path

from fastapi import Depends, HTTPException, status
from pydantic import BaseModel, Field

import app.main as core
from app.dual_tts import (
    KOKORO_ENGINE,
    SUPPORTED_ENGINES,
    audio_extension,
    generate as generate_dual_tts,
    is_valid_voice,
    voice_list,
)
from app.main import STATIC_DIR, app

DEFAULT_PREVIEW_TEXT = (
    "嗨，今天聊点轻松的。I really like simple tools that just work. "
    "最近我在用 ChatGPT 和 LangChain 做 AI 小工具，and it feels pretty useful. "
    "好，我们继续吧。"
)
PREVIEW_ROOT = STATIC_DIR / "previews"
MANIFEST_PATH = PREVIEW_ROOT / "manifest.json"
_MANIFEST_LOCK = threading.Lock()
_JOBS: dict[str, dict] = {}
_JOB_TASKS: dict[str, asyncio.Task] = {}

PREVIEW_ROOT.mkdir(parents=True, exist_ok=True)


class PreviewTextRequest(BaseModel):
    text: str = Field(min_length=1, max_length=3000)


class PreviewGenerateRequest(BaseModel):
    engine: str
    voice: str
    speed: float = Field(default=1.0, ge=0.5, le=2.0)


class PreviewBatchRequest(BaseModel):
    engine: str
    priority_voice: str | None = None
    speed: float = Field(default=1.0, ge=0.5, le=2.0)


def _now() -> str:
    return datetime.now().isoformat(timespec="seconds")


def _text_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def _default_manifest() -> dict:
    return {
        "version": 2,
        "text": DEFAULT_PREVIEW_TEXT,
        "text_hash": _text_hash(DEFAULT_PREVIEW_TEXT),
        "updated_at": _now(),
        "kokoro": {},
        "edge": {},
    }


def _read_manifest_unlocked() -> dict:
    data = _default_manifest()
    if MANIFEST_PATH.exists():
        try:
            raw = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                text = str(raw.get("text") or DEFAULT_PREVIEW_TEXT).strip() or DEFAULT_PREVIEW_TEXT
                data.update(raw)
                data["text"] = text
                data["text_hash"] = _text_hash(text)
                for engine_name in ("kokoro", "edge"):
                    normalized: dict[str, dict] = {}
                    old_map = raw.get(engine_name) if isinstance(raw.get(engine_name), dict) else {}
                    for voice, value in old_map.items():
                        if isinstance(value, str):
                            normalized[voice] = {
                                "url": value,
                                "text_hash": _text_hash(text),
                                "updated_at": raw.get("updated_at"),
                            }
                        elif isinstance(value, dict) and value.get("url"):
                            normalized[voice] = dict(value)
                    data[engine_name] = normalized
        except (OSError, json.JSONDecodeError):
            pass
    return data


def _write_manifest_unlocked(data: dict) -> None:
    PREVIEW_ROOT.mkdir(parents=True, exist_ok=True)
    data["version"] = 2
    data["text_hash"] = _text_hash(str(data.get("text") or DEFAULT_PREVIEW_TEXT))
    data["updated_at"] = _now()
    tmp = MANIFEST_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(MANIFEST_PATH)


def _load_manifest() -> dict:
    with _MANIFEST_LOCK:
        return _read_manifest_unlocked()


def _save_text(text: str) -> dict:
    with _MANIFEST_LOCK:
        data = _read_manifest_unlocked()
        data["text"] = text
        _write_manifest_unlocked(data)
        return data


def _preview_path_from_url(url: str) -> Path | None:
    if not url.startswith("/static/previews/"):
        return None
    rel = url.removeprefix("/static/")
    candidate = (STATIC_DIR / rel).resolve()
    try:
        candidate.relative_to(STATIC_DIR.resolve())
    except ValueError:
        return None
    return candidate


def _manifest_for_client() -> dict:
    data = _load_manifest()
    current_hash = _text_hash(data["text"])
    result = {
        "version": 2,
        "text": data["text"],
        "text_hash": current_hash,
        "updated_at": data.get("updated_at"),
        "kokoro": {},
        "edge": {},
        "counts": {},
        "mode": "manual-persistent",
    }
    for engine_name in ("kokoro", "edge"):
        ready = 0
        current = 0
        total = len(voice_list(engine_name))
        for voice, entry in data.get(engine_name, {}).items():
            if not isinstance(entry, dict) or not entry.get("url"):
                continue
            path = _preview_path_from_url(str(entry["url"]))
            min_size = 512 if engine_name == "edge" else 44
            if path is None or not path.exists() or path.stat().st_size <= min_size:
                continue
            ready += 1
            stale = entry.get("text_hash") != current_hash
            if not stale:
                current += 1
            result[engine_name][voice] = {
                **entry,
                "stale": stale,
                "bytes": path.stat().st_size,
            }
        result["counts"][engine_name] = {
            "ready": ready,
            "current": current,
            "total": total,
        }
    return result


def _validate_engine_voice(engine_name: str, voice: str) -> tuple[str, str]:
    selected = (engine_name or "").strip().lower()
    voice = (voice or "").strip()
    if selected not in SUPPORTED_ENGINES:
        raise HTTPException(status_code=400, detail="Unknown TTS engine")
    if not is_valid_voice(selected, voice):
        raise HTTPException(status_code=400, detail=f"Unknown voice for engine {selected}")
    return selected, voice


def _job_snapshot(job_id: str) -> dict:
    job = _JOBS.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Preview job not found")
    return dict(job)


def _new_job(kind: str, engine_name: str, total: int, voice: str | None = None) -> dict:
    job_id = f"preview_{secrets.token_hex(6)}"
    job = {
        "id": job_id,
        "kind": kind,
        "engine": engine_name,
        "voice": voice,
        "status": "queued",
        "total": total,
        "completed": 0,
        "failed": 0,
        "skipped": 0,
        "current_voice": None,
        "error": None,
        "created_at": _now(),
        "updated_at": _now(),
    }
    _JOBS[job_id] = job
    if len(_JOBS) > 100:
        finished = [k for k, v in _JOBS.items() if v.get("status") in {"completed", "failed", "cancelled"}]
        for old_id in finished[: max(0, len(_JOBS) - 100)]:
            _JOBS.pop(old_id, None)
            _JOB_TASKS.pop(old_id, None)
    return job


def _entry_is_current(manifest: dict, engine_name: str, voice: str) -> bool:
    entry = manifest.get(engine_name, {}).get(voice)
    if not isinstance(entry, dict) or not entry.get("url"):
        return False
    path = _preview_path_from_url(str(entry["url"]))
    min_size = 512 if engine_name == "edge" else 44
    return bool(
        path
        and path.exists()
        and path.stat().st_size > min_size
        and entry.get("text_hash") == _text_hash(manifest["text"])
    )


async def _generate_one(engine_name: str, voice: str, speed: float, text: str, text_hash: str, job_id: str) -> dict:
    engine_dir = PREVIEW_ROOT / engine_name
    engine_dir.mkdir(parents=True, exist_ok=True)
    ext = audio_extension(engine_name)
    target = engine_dir / f"{voice}{ext}"
    tmp = engine_dir / f".{voice}.{job_id}{ext}"
    tmp.unlink(missing_ok=True)

    try:
        if engine_name == KOKORO_ENGINE:
            async with core.tts_lock:
                duration = await asyncio.to_thread(generate_dual_tts, engine_name, text, voice, speed, tmp)
        else:
            duration = await asyncio.to_thread(generate_dual_tts, engine_name, text, voice, speed, tmp)

        min_size = 512 if engine_name == "edge" else 44
        if not tmp.exists() or tmp.stat().st_size <= min_size:
            raise RuntimeError("preview generation finished without a valid audio file")
        tmp.replace(target)
        entry = {
            "url": f"/static/previews/{engine_name}/{target.name}",
            "text_hash": text_hash,
            "updated_at": _now(),
            "duration": round(float(duration), 3),
            "bytes": target.stat().st_size,
            "speed": float(speed),
        }
        with _MANIFEST_LOCK:
            manifest = _read_manifest_unlocked()
            manifest.setdefault(engine_name, {})[voice] = entry
            _write_manifest_unlocked(manifest)
        return entry
    finally:
        tmp.unlink(missing_ok=True)


async def _run_single_job(job_id: str, engine_name: str, voice: str, speed: float, text: str, text_hash: str) -> None:
    job = _JOBS[job_id]
    job.update(status="processing", current_voice=voice, updated_at=_now())
    try:
        await _generate_one(engine_name, voice, speed, text, text_hash, job_id)
        job.update(status="completed", completed=1, current_voice=None, updated_at=_now())
    except asyncio.CancelledError:
        job.update(status="cancelled", current_voice=None, updated_at=_now())
        raise
    except Exception as exc:
        job.update(status="failed", failed=1, current_voice=None, error=f"{type(exc).__name__}: {exc}"[:1000], updated_at=_now())


async def _run_batch_job(
    job_id: str,
    engine_name: str,
    voices: list[str],
    speed: float,
    text: str,
    text_hash: str,
) -> None:
    job = _JOBS[job_id]
    job.update(status="processing", updated_at=_now())
    errors: list[str] = []
    for voice in voices:
        try:
            manifest = _load_manifest()
            if manifest.get("text") == text and _entry_is_current(manifest, engine_name, voice):
                job["skipped"] += 1
                job["completed"] += 1
                job.update(current_voice=voice, updated_at=_now())
                continue
            job.update(current_voice=voice, updated_at=_now())
            await _generate_one(engine_name, voice, speed, text, text_hash, job_id)
            job["completed"] += 1
        except asyncio.CancelledError:
            job.update(status="cancelled", current_voice=None, updated_at=_now())
            raise
        except Exception as exc:
            job["failed"] += 1
            errors.append(f"{voice}: {type(exc).__name__}: {exc}")
        job["updated_at"] = _now()

    job["current_voice"] = None
    job["error"] = "\n".join(errors[-5:])[:2000] if errors else None
    job["status"] = "failed" if job["completed"] == 0 and job["failed"] else "completed"
    job["updated_at"] = _now()


@app.get("/admin/previews", dependencies=[Depends(core.admin_required)])
def admin_previews() -> dict:
    return _manifest_for_client()


@app.put("/admin/previews/text", dependencies=[Depends(core.admin_required)])
def save_preview_text(payload: PreviewTextRequest) -> dict:
    text = payload.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="Preview text is empty")
    _save_text(text)
    return _manifest_for_client()


@app.post("/admin/previews/generate", status_code=status.HTTP_202_ACCEPTED, dependencies=[Depends(core.admin_required)])
async def generate_preview(payload: PreviewGenerateRequest) -> dict:
    engine_name, voice = _validate_engine_voice(payload.engine, payload.voice)
    for job in _JOBS.values():
        if job.get("status") in {"queued", "processing"} and job.get("kind") == "single" and job.get("engine") == engine_name and job.get("voice") == voice:
            return dict(job)
    manifest = _load_manifest()
    text = manifest["text"]
    text_hash = _text_hash(text)
    job = _new_job("single", engine_name, 1, voice)
    task = asyncio.create_task(_run_single_job(job["id"], engine_name, voice, payload.speed, text, text_hash), name=job["id"])
    _JOB_TASKS[job["id"]] = task
    return dict(job)


@app.post("/admin/previews/generate-batch", status_code=status.HTTP_202_ACCEPTED, dependencies=[Depends(core.admin_required)])
async def generate_preview_batch(payload: PreviewBatchRequest) -> dict:
    engine_name = (payload.engine or "").strip().lower()
    if engine_name not in SUPPORTED_ENGINES:
        raise HTTPException(status_code=400, detail="Unknown TTS engine")
    for job in _JOBS.values():
        if job.get("status") in {"queued", "processing"} and job.get("kind") == "batch" and job.get("engine") == engine_name:
            return dict(job)

    voices = [item["id"] for item in voice_list(engine_name)]
    priority = (payload.priority_voice or "").strip()
    if priority and priority in voices:
        voices = [priority] + [voice for voice in voices if voice != priority]
    manifest = _load_manifest()
    text = manifest["text"]
    text_hash = _text_hash(text)
    job = _new_job("batch", engine_name, len(voices))
    task = asyncio.create_task(
        _run_batch_job(job["id"], engine_name, voices, payload.speed, text, text_hash),
        name=job["id"],
    )
    _JOB_TASKS[job["id"]] = task
    return dict(job)


@app.get("/admin/previews/jobs/{job_id}", dependencies=[Depends(core.admin_required)])
def preview_job(job_id: str) -> dict:
    return _job_snapshot(job_id)


@app.post("/admin/previews/jobs/{job_id}/cancel", dependencies=[Depends(core.admin_required)])
def cancel_preview_job(job_id: str) -> dict:
    job = _JOBS.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Preview job not found")
    task = _JOB_TASKS.get(job_id)
    if task and not task.done():
        task.cancel()
        job.update(status="cancelled", current_voice=None, updated_at=_now())
    return dict(job)
