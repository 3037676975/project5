from __future__ import annotations

import sys

from fastapi import Depends, HTTPException
from pydantic import BaseModel, Field

SUPPORTED_NOTE_ENGINES = {"kokoro", "edge"}


class VoiceNoteRequest(BaseModel):
    engine: str
    voice: str = Field(min_length=1, max_length=128)
    note: str = Field(default="", max_length=500)


# app.entry imports app.main before app.dual_tts, so the FastAPI app already exists
# in the real server path. Standalone imports of app.dual_tts (for synthesis/tests)
# must stay lightweight and must not force app.main/ADMIN_KEY initialization.
core = sys.modules.get("app.main")
ROUTES_REGISTERED = bool(core is not None and hasattr(core, "app"))

if ROUTES_REGISTERED:
    app = core.app

    def _ensure_schema() -> None:
        with core.db() as conn:
            conn.execute(
                """CREATE TABLE IF NOT EXISTS voice_notes (
                    engine TEXT NOT NULL,
                    voice TEXT NOT NULL,
                    note TEXT NOT NULL DEFAULT '',
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (engine, voice)
                )"""
            )
            conn.execute("CREATE INDEX IF NOT EXISTS idx_voice_notes_engine ON voice_notes(engine, voice)")

    _ensure_schema()

    def _normalize_engine(value: str | None) -> str:
        engine = (value or "").strip().lower()
        if engine and engine not in SUPPORTED_NOTE_ENGINES:
            raise HTTPException(status_code=400, detail="Unknown TTS engine")
        return engine

    def _notes_payload(engine: str = "") -> dict:
        sql = "SELECT engine, voice, note, updated_at FROM voice_notes"
        params: tuple = ()
        if engine:
            sql += " WHERE engine=?"
            params = (engine,)
        sql += " ORDER BY engine, voice"

        result = {"kokoro": {}, "edge": {}}
        with core.db() as conn:
            for row in conn.execute(sql, params).fetchall():
                result[row["engine"]][row["voice"]] = {
                    "note": row["note"],
                    "updated_at": row["updated_at"],
                }
        return {"mode": "server-persistent", "notes": result}

    @app.get("/admin/voice-notes", dependencies=[Depends(core.admin_required)])
    def list_voice_notes(engine: str | None = None) -> dict:
        return _notes_payload(_normalize_engine(engine))

    @app.put("/admin/voice-notes", dependencies=[Depends(core.admin_required)])
    def save_voice_note(payload: VoiceNoteRequest) -> dict:
        engine = _normalize_engine(payload.engine)
        voice = payload.voice.strip()
        note = payload.note.strip()
        if not voice:
            raise HTTPException(status_code=400, detail="Voice is empty")

        with core.db() as conn:
            if note:
                conn.execute(
                    """INSERT INTO voice_notes(engine, voice, note, updated_at)
                    VALUES(?,?,?,?)
                    ON CONFLICT(engine, voice) DO UPDATE SET
                        note=excluded.note,
                        updated_at=excluded.updated_at""",
                    (engine, voice, note, core.now()),
                )
            else:
                conn.execute("DELETE FROM voice_notes WHERE engine=? AND voice=?", (engine, voice))

        return _notes_payload(engine)
