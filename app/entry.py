from __future__ import annotations

import asyncio
import json
import secrets
import time
from contextlib import suppress
from datetime import datetime
from pathlib import Path

from fastapi import Depends, Header, HTTPException, Request, status
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel, Field

import app.main as core
from app.dual_tts import (
    EDGE_ENGINE,
    KOKORO_ENGINE,
    SUPPORTED_ENGINES,
    audio_extension,
    default_voice,
    generate as generate_dual_tts,
    is_valid_voice,
    model_name,
    normalize_engine,
    voice_list,
)
from app.main import LOG_DIR, STATIC_DIR, app
from app.tts import CONFIG_PATH, MODEL_PATH, VOICES_PATH, engine

# Registers the administrator-controlled fixed-preview API. Importing this module
# does not start any synthesis job; previews are generated only after an explicit
# action from the console. Use an alias so the package name never shadows the
# FastAPI `app` object imported above.
from app import preview_admin as _preview_admin  # noqa: F401,E402


# ---------------------------------------------------------------------------
# Schema migration: keep every old task valid and add the selected TTS engine.
# ---------------------------------------------------------------------------
def _ensure_dual_engine_schema() -> None:
    with core.db() as conn:
        columns = {row["name"] for row in conn.execute("PRAGMA table_info(tts_tasks)").fetchall()}
        if "engine" not in columns:
            conn.execute("ALTER TABLE tts_tasks ADD COLUMN engine TEXT NOT NULL DEFAULT 'kokoro'")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_tasks_engine ON tts_tasks(engine, created_at DESC)")


_ensure_dual_engine_schema()


class DualSpeechRequest(BaseModel):
    input: str = Field(min_length=1, max_length=core.MAX_TEXT_LENGTH)
    engine: str = KOKORO_ENGINE
    voice: str | None = None
    speed: float = Field(default=1.0, ge=0.5, le=2.0)


def _remove_route(path: str, method: str) -> None:
    for route in list(app.router.routes):
        methods = getattr(route, "methods", set()) or set()
        if getattr(route, "path", None) == path and method in methods:
            app.router.routes.remove(route)


for _path, _method in (
    ("/", "GET"),
    ("/health", "GET"),
    ("/v1/voices", "GET"),
    ("/v1/audio/speech", "POST"),
    ("/admin/speech", "POST"),
    ("/audio/{filename}", "GET"),
):
    _remove_route(_path, _method)


def _create_dual_task_record(
    payload: DualSpeechRequest,
    source_name: str,
    ip: str,
    api_key_id: int | None,
) -> dict:
    selected_engine = normalize_engine(payload.engine, payload.voice)
    voice = (payload.voice or default_voice(selected_engine)).strip()
    selected_engine = normalize_engine(selected_engine, voice)

    if selected_engine not in SUPPORTED_ENGINES:
        raise HTTPException(status_code=400, detail="Unknown TTS engine")
    if not is_valid_voice(selected_engine, voice):
        raise HTTPException(status_code=400, detail=f"Unknown voice for engine {selected_engine}")

    text = payload.input.strip()
    if not text:
        raise HTTPException(status_code=400, detail="Input text is empty")

    task_id = f"tts_{datetime.now():%Y%m%d}_{secrets.token_hex(5)}"
    created = core.now()
    with core.db() as conn:
        conn.execute(
            """INSERT INTO tts_tasks
            (id,api_key_id,source_name,source_ip,input_text,engine,voice,speed,chars,status,created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
            (
                task_id,
                api_key_id,
                source_name,
                ip,
                text,
                selected_engine,
                voice,
                payload.speed,
                len(text),
                "queued",
                created,
            ),
        )
        row = conn.execute("SELECT * FROM tts_tasks WHERE id=?", (task_id,)).fetchone()
    return core.task_to_dict(row)


async def _run_dual_task(task_id: str) -> None:
    row = core.get_task(task_id)
    if not row or row["status"] != "queued":
        return

    selected_engine = normalize_engine(row["engine"], row["voice"])
    filename = f"{task_id}{audio_extension(selected_engine)}"
    output = core.AUDIO_DIR / filename
    output.unlink(missing_ok=True)

    with core.db() as conn:
        updated = conn.execute(
            "UPDATE tts_tasks SET status='processing',error=NULL,completed_at=NULL WHERE id=? AND status='queued'",
            (task_id,),
        ).rowcount
    if updated != 1:
        return

    started = time.perf_counter()
    try:
        if selected_engine == KOKORO_ENGINE:
            async with core.tts_lock:
                duration = await asyncio.to_thread(
                    generate_dual_tts,
                    selected_engine,
                    row["input_text"],
                    row["voice"],
                    float(row["speed"]),
                    output,
                )
        else:
            duration = await asyncio.to_thread(
                generate_dual_tts,
                selected_engine,
                row["input_text"],
                row["voice"],
                float(row["speed"]),
                output,
            )

        min_size = 512 if selected_engine == EDGE_ENGINE else 44
        if not output.exists() or output.stat().st_size <= min_size:
            raise RuntimeError(f"{selected_engine} TTS finished without a valid audio file")

        elapsed = int((time.perf_counter() - started) * 1000)
        file_size = output.stat().st_size
        with core.db() as conn:
            conn.execute(
                """UPDATE tts_tasks
                SET status='completed',engine=?,audio_filename=?,duration=?,file_size=?,
                    elapsed_ms=?,completed_at=?,error=NULL
                WHERE id=?""",
                (selected_engine, filename, duration, file_size, elapsed, core.now(), task_id),
            )
    except Exception as exc:
        output.unlink(missing_ok=True)
        elapsed = int((time.perf_counter() - started) * 1000)
        with core.db() as conn:
            conn.execute(
                """UPDATE tts_tasks
                SET status='failed',engine=?,error=?,elapsed_ms=?,completed_at=?
                WHERE id=?""",
                (
                    selected_engine,
                    f"{selected_engine}: {type(exc).__name__}: {exc}"[:1000],
                    elapsed,
                    core.now(),
                    task_id,
                ),
            )


core.run_task = _run_dual_task

_extra_worker: asyncio.Task | None = None


@app.on_event("startup")
async def start_second_tts_worker() -> None:
    global _extra_worker
    if core.task_queue is not None:
        _extra_worker = asyncio.create_task(core.task_worker(), name="project5-tts-worker-2")


@app.on_event("shutdown")
async def stop_second_tts_worker() -> None:
    global _extra_worker
    if _extra_worker:
        _extra_worker.cancel()
        with suppress(asyncio.CancelledError):
            await _extra_worker
        _extra_worker = None


@app.get("/")
def project5_console() -> HTMLResponse:
    # Serve the real dual-engine page and inject the manual preview manager. The
    # preview JS is separate so deployments can evolve the preview workflow without
    # returning to fragile DOM-overlay logic for the main console.
    html = (STATIC_DIR / "console-v2.html").read_text(encoding="utf-8")
    preview_script = '<script src="/static/preview-admin.js?v=manual-preview-v1"></script>'
    if preview_script not in html:
        html = html.replace("</body>", preview_script + "</body>")
    return HTMLResponse(
        html,
        headers={
            "Cache-Control": "no-cache, no-store, must-revalidate",
            "Pragma": "no-cache",
            "Expires": "0",
            "X-Project5-Console": "dual-engine-v2",
            "X-Project5-Preview": "manual-persistent-v1",
        },
    )


@app.get("/health")
def health() -> dict:
    with core.db() as conn:
        queued = conn.execute("SELECT COUNT(*) c FROM tts_tasks WHERE status='queued'").fetchone()["c"]
        processing = conn.execute("SELECT COUNT(*) c FROM tts_tasks WHERE status='processing'").fetchone()["c"]
    return {
        "status": "ok",
        "service": "project5",
        "model": core.REPO_ID,
        "model_loaded": engine.loaded,
        "device": engine.device,
        "console": "dual-engine-v2",
        "preview_mode": "manual-persistent-v1",
        "engines": {
            KOKORO_ENGINE: {
                "name": "Kokoro-82M-v1.1-zh",
                "mode": "local-cpu",
                "ready": engine.loaded,
                "mixed_zh_en": True,
            },
            EDGE_ENGINE: {
                "name": "Microsoft Edge Online TTS",
                "mode": "online",
                "ready": True,
                "requires_internet": True,
            },
        },
        "queue": {"queued": queued, "processing": processing},
    }


@app.get("/v1/voices")
def voices(engine_name: str | None = None, engine: str | None = None) -> dict:
    selected = (engine_name or engine or "").strip().lower()
    if selected and selected not in SUPPORTED_ENGINES:
        raise HTTPException(status_code=400, detail="Unknown TTS engine")
    items = voice_list(selected or None)
    return {
        "engine": selected or "all",
        "engines": [
            {"id": KOKORO_ENGINE, "label": "Kokoro 本地 CPU", "model": "Kokoro-82M-v1.1-zh"},
            {"id": EDGE_ENGINE, "label": "Edge 在线 TTS", "model": "Microsoft Edge Online TTS"},
        ],
        "voices": items,
    }


@app.post("/admin/speech", status_code=status.HTTP_202_ACCEPTED, dependencies=[Depends(core.admin_required)])
async def admin_speech(payload: DualSpeechRequest, request: Request) -> dict:
    task = _create_dual_task_record(payload, "console", core.client_ip(request), None)
    await core.enqueue_task(task["id"])
    task["task_url"] = f"/admin/tasks/{task['id']}"
    task["model"] = model_name(task["engine"])
    return task


@app.post("/v1/audio/speech", status_code=status.HTTP_202_ACCEPTED)
async def speech_api(
    payload: DualSpeechRequest,
    request: Request,
    authorization: str | None = Header(default=None),
) -> dict:
    started = time.perf_counter()
    ip = core.client_ip(request)
    key = core.get_api_key(authorization)
    if not key:
        elapsed = int((time.perf_counter() - started) * 1000)
        core.write_log(None, ip, "POST", "/v1/audio/speech", 401, elapsed)
        raise HTTPException(status_code=401, detail="Invalid API key")

    core.count_api_key_call(key["id"])
    task = _create_dual_task_record(payload, key["name"], ip, key["id"])
    await core.enqueue_task(task["id"])
    elapsed = int((time.perf_counter() - started) * 1000)
    core.write_log(key["id"], ip, "POST", "/v1/audio/speech", 202, elapsed, task["id"])
    task["model"] = model_name(task["engine"])
    task["task_url"] = str(request.base_url).rstrip("/") + f"/v1/tasks/{task['id']}"
    return task


@app.get("/audio/{filename}")
def audio_file(filename: str) -> FileResponse:
    if Path(filename).name != filename:
        raise HTTPException(status_code=404, detail="File not found")
    with core.db() as conn:
        row = conn.execute(
            "SELECT audio_filename FROM tts_tasks WHERE audio_filename=? AND status='completed'",
            (filename,),
        ).fetchone()
    path = core.AUDIO_DIR / filename
    if not row or not path.exists():
        raise HTTPException(status_code=404, detail="File not found")
    media_type = "audio/mpeg" if path.suffix.lower() == ".mp3" else "audio/wav"
    return FileResponse(path, media_type=media_type, filename=filename)


def _safe_error() -> str | None:
    if not engine.load_error:
        return None
    return engine.load_error.replace(str(MODEL_PATH.parent.parent), ".")


def _file_state(path: Path) -> dict:
    try:
        return {
            "name": path.name,
            "exists": path.exists(),
            "bytes": path.stat().st_size if path.exists() else 0,
        }
    except OSError as exc:
        return {"name": path.name, "exists": False, "bytes": 0, "error": str(exc)}


def _last_selfcheck() -> dict | None:
    path = LOG_DIR / "last-selfcheck.json"
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            return data
    except (OSError, json.JSONDecodeError):
        pass
    return {"status": "invalid", "message": "last-selfcheck.json could not be parsed"}


@app.get("/runtime")
def project5_runtime() -> dict:
    if engine.loaded:
        state = "ready"
    elif engine.load_error:
        state = "error"
    elif engine.loading:
        state = "loading"
    else:
        state = "not_loaded"

    return {
        "state": state,
        "model_loaded": engine.loaded,
        "model_loading": engine.loading,
        "model_error": _safe_error(),
        "backend": engine.backend,
        "device": engine.device,
        "threads": engine.threads,
        "load_metrics": engine.load_metrics,
        "last_metrics": engine.last_metrics,
        "selfcheck": _last_selfcheck(),
        "console": "dual-engine-v2",
        "preview_mode": "manual-persistent-v1",
        "engines": {
            "kokoro": {
                "state": state,
                "model_loaded": engine.loaded,
                "mixed_zh_en": True,
                "model": "Kokoro-82M-v1.1-zh",
            },
            "edge": {
                "state": "available",
                "model_loaded": True,
                "online": True,
                "model": "Microsoft Edge Online TTS",
                "note": "No local model pack; synthesis requires outbound internet.",
            },
        },
        "files": {
            "model": _file_state(MODEL_PATH),
            "voices": _file_state(VOICES_PATH),
            "config": _file_state(CONFIG_PATH),
        },
    }


@app.middleware("http")
async def project5_response_headers(request, call_next):
    response = await call_next(request)
    path = request.url.path

    if path.startswith("/audio/"):
        filename = path.rsplit("/", 1)[-1]
        response.headers["Content-Disposition"] = f'inline; filename="{filename}"'
        response.headers["Cache-Control"] = "private, max-age=31536000, immutable"
        response.headers["X-Content-Type-Options"] = "nosniff"
    elif path.startswith("/static/previews/"):
        response.headers["Cache-Control"] = "public, max-age=31536000, immutable"
    elif path == "/v1/voices":
        response.headers["Cache-Control"] = "public, max-age=300, stale-while-revalidate=3600"
    elif path in {"/", "/runtime", "/health"} or path.startswith("/admin/previews"):
        response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"

    return response
