from __future__ import annotations

import asyncio
from contextlib import suppress
from datetime import datetime, timedelta

from fastapi import Depends
from pydantic import BaseModel

import app.main as core
from app.main import app

SETTING_KEY = "audio_retention_24h"
RETENTION_HOURS = 24
CLEANUP_INTERVAL_SECONDS = 600
_cleanup_task: asyncio.Task | None = None


class RetentionUpdate(BaseModel):
    enabled: bool


def _ensure_schema() -> None:
    with core.db() as conn:
        conn.execute(
            """CREATE TABLE IF NOT EXISTS service_settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )"""
        )


_ensure_schema()


def retention_enabled() -> bool:
    with core.db() as conn:
        row = conn.execute("SELECT value FROM service_settings WHERE key=?", (SETTING_KEY,)).fetchone()
    return bool(row and str(row["value"]).strip().lower() in {"1", "true", "yes", "on"})


def _set_enabled(enabled: bool) -> None:
    with core.db() as conn:
        conn.execute(
            """INSERT INTO service_settings(key,value,updated_at)
            VALUES(?,?,?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at""",
            (SETTING_KEY, "1" if enabled else "0", core.now()),
        )


def _cutoff_iso() -> str:
    return (datetime.now() - timedelta(hours=RETENTION_HOURS)).isoformat(timespec="seconds")


def retention_status() -> dict:
    enabled = retention_enabled()
    cutoff = _cutoff_iso()
    with core.db() as conn:
        retained = conn.execute(
            "SELECT COUNT(*) c, COALESCE(SUM(file_size),0) bytes FROM tts_tasks WHERE status='completed' AND audio_filename IS NOT NULL"
        ).fetchone()
        expired = conn.execute(
            """SELECT COUNT(*) c, COALESCE(SUM(file_size),0) bytes
            FROM tts_tasks
            WHERE status='completed' AND audio_filename IS NOT NULL
              AND COALESCE(completed_at, created_at) < ?""",
            (cutoff,),
        ).fetchone()
    return {
        "enabled": enabled,
        "hours": RETENTION_HOURS,
        "mode": "24h-auto-clean" if enabled else "manual",
        "retained_files": int(retained["c"] or 0),
        "retained_bytes": int(retained["bytes"] or 0),
        "expired_files": int(expired["c"] or 0),
        "expired_bytes": int(expired["bytes"] or 0),
        "fixed_previews_excluded": True,
        "task_history_preserved": True,
    }


def cleanup_expired_audio(force: bool = False) -> dict:
    enabled = retention_enabled()
    if not enabled and not force:
        return {"ok": True, "skipped": True, "reason": "retention_disabled", **retention_status()}

    cutoff = _cutoff_iso()
    with core.db() as conn:
        rows = conn.execute(
            """SELECT id,audio_filename,file_size,COALESCE(completed_at,created_at) finished_at
            FROM tts_tasks
            WHERE status='completed' AND audio_filename IS NOT NULL
              AND COALESCE(completed_at, created_at) < ?
            ORDER BY COALESCE(completed_at, created_at) ASC""",
            (cutoff,),
        ).fetchall()

    deleted = 0
    deleted_bytes = 0
    missing = 0
    cleaned_ids: list[str] = []
    for row in rows:
        filename = str(row["audio_filename"] or "")
        if not filename or filename != __import__("pathlib").Path(filename).name:
            continue
        path = core.AUDIO_DIR / filename
        size = int(row["file_size"] or 0)
        try:
            if path.exists():
                if not size:
                    size = path.stat().st_size
                path.unlink()
                deleted += 1
                deleted_bytes += size
            else:
                missing += 1
            cleaned_ids.append(row["id"])
        except OSError:
            continue

    if cleaned_ids:
        with core.db() as conn:
            conn.executemany(
                "UPDATE tts_tasks SET audio_filename=NULL,file_size=NULL WHERE id=?",
                [(task_id,) for task_id in cleaned_ids],
            )

    return {
        "ok": True,
        "skipped": False,
        "deleted_files": deleted,
        "deleted_bytes": deleted_bytes,
        "missing_files": missing,
        "cleaned_task_records": len(cleaned_ids),
        **retention_status(),
    }


@app.get("/admin/audio-retention", dependencies=[Depends(core.admin_required)])
def get_audio_retention() -> dict:
    return retention_status()


@app.put("/admin/audio-retention", dependencies=[Depends(core.admin_required)])
def set_audio_retention(payload: RetentionUpdate) -> dict:
    _set_enabled(payload.enabled)
    cleanup = cleanup_expired_audio() if payload.enabled else None
    return {**retention_status(), "cleanup": cleanup}


@app.post("/admin/audio-retention/cleanup", dependencies=[Depends(core.admin_required)])
def run_audio_retention_cleanup() -> dict:
    # Manual cleanup means "apply the 24-hour rule now"; it does not delete fresh audio.
    return cleanup_expired_audio(force=True)


async def _cleanup_loop() -> None:
    while True:
        try:
            if retention_enabled():
                await asyncio.to_thread(cleanup_expired_audio)
        except Exception:
            # Cleanup must never take down the TTS service.
            pass
        await asyncio.sleep(CLEANUP_INTERVAL_SECONDS)


@app.on_event("startup")
async def start_audio_retention_worker() -> None:
    global _cleanup_task
    if retention_enabled():
        await asyncio.to_thread(cleanup_expired_audio)
    if _cleanup_task is None or _cleanup_task.done():
        _cleanup_task = asyncio.create_task(_cleanup_loop(), name="project5-audio-retention")


@app.on_event("shutdown")
async def stop_audio_retention_worker() -> None:
    global _cleanup_task
    if _cleanup_task:
        _cleanup_task.cancel()
        with suppress(asyncio.CancelledError):
            await _cleanup_task
        _cleanup_task = None
