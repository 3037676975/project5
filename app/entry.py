from __future__ import annotations

import json
from pathlib import Path

from fastapi.responses import HTMLResponse

from app.main import LOG_DIR, STATIC_DIR, app
from app.tts import CONFIG_PATH, MODEL_PATH, VOICES_PATH, engine

for route in list(app.router.routes):
    if getattr(route, "path", None) == "/" and "GET" in (getattr(route, "methods", set()) or set()):
        app.router.routes.remove(route)


@app.get("/", response_class=HTMLResponse)
def project5_console() -> HTMLResponse:
    html = (STATIC_DIR / "index.html").read_text(encoding="utf-8")
    marker = "</body>"
    scripts = (
        '<script src="/static/runtime-overlay.js?v=20260906-2"></script>\n'
        '<script src="/static/task-v2.js?v=20260906-1"></script>'
    )
    if "/static/task-v2.js" not in html:
        html = html.replace(marker, scripts + "\n" + marker)
    return HTMLResponse(html, headers={"Cache-Control": "no-cache, no-store, must-revalidate"})


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
    elif path == "/v1/voices":
        response.headers["Cache-Control"] = "public, max-age=86400, stale-while-revalidate=604800"
    elif path in {"/", "/runtime", "/health"}:
        response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"

    return response
