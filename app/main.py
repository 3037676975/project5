from __future__ import annotations

import asyncio
import hashlib
import hmac
import os
import secrets
import sqlite3
import time
from datetime import date, datetime, timedelta
from pathlib import Path

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

ROOT = Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")

from app.tts import CHINESE_VOICES, REPO_ID, engine, voice_meta  # noqa: E402

DATA_DIR = ROOT / "data"
AUDIO_DIR = DATA_DIR / "audio"
DB_PATH = DATA_DIR / "project5.db"
STATIC_DIR = ROOT / "app" / "static"
LOG_DIR = ROOT / "logs"
MAX_TEXT_LENGTH = int(os.getenv("MAX_TEXT_LENGTH", "5000"))
ADMIN_KEY = os.getenv("ADMIN_KEY", "").strip()

DATA_DIR.mkdir(parents=True, exist_ok=True)
AUDIO_DIR.mkdir(parents=True, exist_ok=True)
LOG_DIR.mkdir(parents=True, exist_ok=True)

if not ADMIN_KEY:
    raise RuntimeError("ADMIN_KEY is missing. Run scripts/auto-deploy.sh or create .env first.")

app = FastAPI(
    title="Project5 Kokoro TTS API",
    version="1.0.0",
    description="A lightweight Chinese TTS API platform powered only by Kokoro-82M-v1.1-zh.",
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

tts_lock = asyncio.Lock()


def now() -> str:
    return datetime.now().isoformat(timespec="seconds")


def db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db() -> None:
    with db() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS api_keys (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                key_hash TEXT NOT NULL UNIQUE,
                key_prefix TEXT NOT NULL,
                active INTEGER NOT NULL DEFAULT 1,
                calls INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                last_used_at TEXT
            );

            CREATE TABLE IF NOT EXISTS tts_tasks (
                id TEXT PRIMARY KEY,
                api_key_id INTEGER,
                source_name TEXT NOT NULL,
                source_ip TEXT,
                input_text TEXT NOT NULL,
                voice TEXT NOT NULL,
                speed REAL NOT NULL,
                chars INTEGER NOT NULL,
                status TEXT NOT NULL,
                error TEXT,
                audio_filename TEXT,
                duration REAL,
                file_size INTEGER,
                elapsed_ms INTEGER,
                created_at TEXT NOT NULL,
                completed_at TEXT,
                FOREIGN KEY(api_key_id) REFERENCES api_keys(id) ON DELETE SET NULL
            );

            CREATE TABLE IF NOT EXISTS api_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                api_key_id INTEGER,
                source_ip TEXT,
                method TEXT NOT NULL,
                path TEXT NOT NULL,
                status_code INTEGER NOT NULL,
                elapsed_ms INTEGER NOT NULL,
                task_id TEXT,
                created_at TEXT NOT NULL,
                FOREIGN KEY(api_key_id) REFERENCES api_keys(id) ON DELETE SET NULL
            );

            CREATE INDEX IF NOT EXISTS idx_tasks_created ON tts_tasks(created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_logs_created ON api_logs(created_at DESC);
            """
        )


init_db()


class SpeechRequest(BaseModel):
    input: str = Field(min_length=1, max_length=MAX_TEXT_LENGTH)
    voice: str = "zf_001"
    speed: float = Field(default=1.0, ge=0.5, le=2.0)


class KeyCreate(BaseModel):
    name: str = Field(min_length=1, max_length=80)


class KeyUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=80)
    active: bool | None = None


def client_ip(request: Request) -> str:
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def key_digest(raw: str) -> str:
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def admin_required(x_admin_key: str | None = Header(default=None, alias="X-Admin-Key")) -> None:
    if not x_admin_key or not hmac.compare_digest(x_admin_key, ADMIN_KEY):
        raise HTTPException(status_code=401, detail="Invalid admin key")


def get_api_key(authorization: str | None) -> sqlite3.Row | None:
    if not authorization or not authorization.lower().startswith("bearer "):
        return None
    raw = authorization.split(" ", 1)[1].strip()
    with db() as conn:
        row = conn.execute(
            "SELECT * FROM api_keys WHERE key_hash=? AND active=1",
            (key_digest(raw),),
        ).fetchone()
        if row:
            conn.execute(
                "UPDATE api_keys SET calls=calls+1,last_used_at=? WHERE id=?",
                (now(), row["id"]),
            )
        return row


def write_log(api_key_id: int | None, ip: str, method: str, path: str, status: int, elapsed_ms: int, task_id: str | None = None) -> None:
    with db() as conn:
        conn.execute(
            "INSERT INTO api_logs(api_key_id,source_ip,method,path,status_code,elapsed_ms,task_id,created_at) VALUES(?,?,?,?,?,?,?,?)",
            (api_key_id, ip, method, path, status, elapsed_ms, task_id, now()),
        )


def task_to_dict(row: sqlite3.Row) -> dict:
    item = dict(row)
    if item.get("audio_filename"):
        item["audio_url"] = f"/audio/{item['audio_filename']}"
    return item


async def generate_task(payload: SpeechRequest, source_name: str, ip: str, api_key_id: int | None) -> dict:
    if payload.voice not in CHINESE_VOICES:
        raise HTTPException(status_code=400, detail="Unknown voice")

    task_id = f"tts_{datetime.now():%Y%m%d}_{secrets.token_hex(5)}"
    filename = f"{task_id}.wav"
    output = AUDIO_DIR / filename
    created = now()
    text = payload.input.strip()

    with db() as conn:
        conn.execute(
            """INSERT INTO tts_tasks
            (id,api_key_id,source_name,source_ip,input_text,voice,speed,chars,status,created_at)
            VALUES(?,?,?,?,?,?,?,?,?,?)""",
            (task_id, api_key_id, source_name, ip, text, payload.voice, payload.speed, len(text), "processing", created),
        )

    started = time.perf_counter()
    try:
        async with tts_lock:
            duration = await asyncio.to_thread(engine.generate, text, payload.voice, payload.speed, output)
        elapsed = int((time.perf_counter() - started) * 1000)
        file_size = output.stat().st_size
        with db() as conn:
            conn.execute(
                """UPDATE tts_tasks SET status='completed',audio_filename=?,duration=?,file_size=?,elapsed_ms=?,completed_at=? WHERE id=?""",
                (filename, duration, file_size, elapsed, now(), task_id),
            )
    except Exception as exc:
        elapsed = int((time.perf_counter() - started) * 1000)
        with db() as conn:
            conn.execute(
                "UPDATE tts_tasks SET status='failed',error=?,elapsed_ms=?,completed_at=? WHERE id=?",
                (str(exc)[:1000], elapsed, now(), task_id),
            )
        raise

    with db() as conn:
        row = conn.execute("SELECT * FROM tts_tasks WHERE id=?", (task_id,)).fetchone()
    return task_to_dict(row)


@app.get("/")
def console() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok",
        "service": "project5",
        "model": REPO_ID,
        "model_loaded": engine.loaded,
        "device": engine.device,
    }


@app.get("/v1/voices")
def voices() -> dict:
    return {"model": "kokoro-82m-v1.1-zh", "voices": [voice_meta(v) for v in CHINESE_VOICES]}


@app.post("/v1/audio/speech")
async def speech_api(payload: SpeechRequest, request: Request, authorization: str | None = Header(default=None)) -> dict:
    started = time.perf_counter()
    ip = client_ip(request)
    key = get_api_key(authorization)
    if not key:
        elapsed = int((time.perf_counter() - started) * 1000)
        write_log(None, ip, "POST", "/v1/audio/speech", 401, elapsed)
        raise HTTPException(status_code=401, detail="Invalid API key")

    try:
        task = await generate_task(payload, key["name"], ip, key["id"])
        elapsed = int((time.perf_counter() - started) * 1000)
        write_log(key["id"], ip, "POST", "/v1/audio/speech", 200, elapsed, task["id"])
        task["model"] = "kokoro-82m-v1.1-zh"
        task["audio_url"] = str(request.base_url).rstrip("/") + task["audio_url"]
        return task
    except HTTPException as exc:
        elapsed = int((time.perf_counter() - started) * 1000)
        write_log(key["id"], ip, "POST", "/v1/audio/speech", exc.status_code, elapsed)
        raise
    except Exception:
        elapsed = int((time.perf_counter() - started) * 1000)
        write_log(key["id"], ip, "POST", "/v1/audio/speech", 500, elapsed)
        raise HTTPException(status_code=500, detail="Speech generation failed. Check task details in the console.")


@app.get("/v1/tasks/{task_id}")
def api_task(task_id: str, request: Request, authorization: str | None = Header(default=None)) -> dict:
    started = time.perf_counter()
    ip = client_ip(request)
    key = get_api_key(authorization)
    if not key:
        write_log(None, ip, "GET", f"/v1/tasks/{task_id}", 401, int((time.perf_counter() - started) * 1000))
        raise HTTPException(status_code=401, detail="Invalid API key")
    with db() as conn:
        row = conn.execute("SELECT * FROM tts_tasks WHERE id=? AND api_key_id=?", (task_id, key["id"])).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Task not found")
    item = task_to_dict(row)
    if item.get("audio_url"):
        item["audio_url"] = str(request.base_url).rstrip("/") + item["audio_url"]
    return item


@app.get("/audio/{filename}")
def audio_file(filename: str) -> FileResponse:
    if Path(filename).name != filename:
        raise HTTPException(status_code=404, detail="File not found")
    with db() as conn:
        row = conn.execute("SELECT audio_filename FROM tts_tasks WHERE audio_filename=? AND status='completed'", (filename,)).fetchone()
    path = AUDIO_DIR / filename
    if not row or not path.exists():
        raise HTTPException(status_code=404, detail="File not found")
    return FileResponse(path, media_type="audio/wav", filename=filename)


@app.get("/admin/stats", dependencies=[Depends(admin_required)])
def admin_stats() -> dict:
    today_prefix = date.today().isoformat()
    days = [(date.today() - timedelta(days=i)).isoformat() for i in range(6, -1, -1)]
    with db() as conn:
        today = conn.execute(
            """SELECT COUNT(*) calls,
            SUM(CASE WHEN status='completed' THEN 1 ELSE 0 END) success,
            SUM(CASE WHEN status='failed' THEN 1 ELSE 0 END) failed,
            COALESCE(SUM(chars),0) chars
            FROM tts_tasks WHERE created_at LIKE ?""",
            (today_prefix + "%",),
        ).fetchone()
        total_keys = conn.execute("SELECT COUNT(*) c FROM api_keys WHERE active=1").fetchone()["c"]
        recent = conn.execute("SELECT * FROM tts_tasks ORDER BY created_at DESC LIMIT 8").fetchall()
        trend_rows = conn.execute(
            "SELECT substr(created_at,1,10) day,COUNT(*) count FROM tts_tasks WHERE created_at>=? GROUP BY day",
            (days[0],),
        ).fetchall()
    trend_map = {r["day"]: r["count"] for r in trend_rows}
    return {
        "today_calls": today["calls"] or 0,
        "today_success": today["success"] or 0,
        "today_failed": today["failed"] or 0,
        "today_chars": today["chars"] or 0,
        "active_keys": total_keys,
        "model_loaded": engine.loaded,
        "trend": [{"day": d, "count": trend_map.get(d, 0)} for d in days],
        "recent": [task_to_dict(r) for r in recent],
    }


@app.get("/admin/keys", dependencies=[Depends(admin_required)])
def list_keys() -> dict:
    with db() as conn:
        rows = conn.execute("SELECT id,name,key_prefix,active,calls,created_at,last_used_at FROM api_keys ORDER BY id DESC").fetchall()
    return {"items": [dict(r) for r in rows]}


@app.post("/admin/keys", dependencies=[Depends(admin_required)])
def create_key(payload: KeyCreate) -> dict:
    raw = "sk-kokoro-" + secrets.token_urlsafe(24)
    prefix = raw[:18]
    with db() as conn:
        cur = conn.execute(
            "INSERT INTO api_keys(name,key_hash,key_prefix,active,calls,created_at) VALUES(?,?,?,1,0,?)",
            (payload.name.strip(), key_digest(raw), prefix, now()),
        )
        key_id = cur.lastrowid
    return {"id": key_id, "name": payload.name.strip(), "key": raw, "key_prefix": prefix, "message": "The full key is shown only in this response."}


@app.patch("/admin/keys/{key_id}", dependencies=[Depends(admin_required)])
def update_key(key_id: int, payload: KeyUpdate) -> dict:
    updates = []
    values = []
    if payload.name is not None:
        updates.append("name=?")
        values.append(payload.name.strip())
    if payload.active is not None:
        updates.append("active=?")
        values.append(1 if payload.active else 0)
    if not updates:
        return {"ok": True}
    values.append(key_id)
    with db() as conn:
        conn.execute(f"UPDATE api_keys SET {','.join(updates)} WHERE id=?", values)
    return {"ok": True}


@app.delete("/admin/keys/{key_id}", dependencies=[Depends(admin_required)])
def delete_key(key_id: int) -> dict:
    with db() as conn:
        conn.execute("DELETE FROM api_keys WHERE id=?", (key_id,))
    return {"ok": True}


@app.post("/admin/speech", dependencies=[Depends(admin_required)])
async def admin_speech(payload: SpeechRequest, request: Request) -> dict:
    try:
        return await generate_task(payload, "console", client_ip(request), None)
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=500, detail="Speech generation failed. Open task details for the error.")


@app.get("/admin/tasks", dependencies=[Depends(admin_required)])
def admin_tasks(limit: int = 100, status: str | None = None) -> dict:
    limit = min(max(limit, 1), 500)
    with db() as conn:
        if status:
            rows = conn.execute("SELECT * FROM tts_tasks WHERE status=? ORDER BY created_at DESC LIMIT ?", (status, limit)).fetchall()
        else:
            rows = conn.execute("SELECT * FROM tts_tasks ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()
    return {"items": [task_to_dict(r) for r in rows]}


@app.get("/admin/tasks/{task_id}", dependencies=[Depends(admin_required)])
def admin_task(task_id: str) -> dict:
    with db() as conn:
        row = conn.execute("SELECT * FROM tts_tasks WHERE id=?", (task_id,)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Task not found")
    return task_to_dict(row)


@app.delete("/admin/tasks/{task_id}", dependencies=[Depends(admin_required)])
def delete_task(task_id: str) -> dict:
    with db() as conn:
        row = conn.execute("SELECT audio_filename FROM tts_tasks WHERE id=?", (task_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Task not found")
        conn.execute("DELETE FROM tts_tasks WHERE id=?", (task_id,))
    if row["audio_filename"]:
        path = AUDIO_DIR / row["audio_filename"]
        path.unlink(missing_ok=True)
    return {"ok": True}


@app.get("/admin/logs", dependencies=[Depends(admin_required)])
def admin_logs(limit: int = 100) -> dict:
    limit = min(max(limit, 1), 500)
    with db() as conn:
        rows = conn.execute(
            """SELECT l.*,k.name api_key_name FROM api_logs l
            LEFT JOIN api_keys k ON k.id=l.api_key_id ORDER BY l.created_at DESC LIMIT ?""",
            (limit,),
        ).fetchall()
    return {"items": [dict(r) for r in rows]}


if os.getenv("PRELOAD_MODEL", "0") == "1":
    engine.load()
