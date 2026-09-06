from __future__ import annotations

from fastapi.responses import HTMLResponse

from app.main import STATIC_DIR, app
from app.tts import CONFIG_PATH, MODEL_PATH, VOICES_PATH, engine


# main.py originally serves / as a raw FileResponse. Replace only that GET route so
# we can load a tiny diagnostics overlay without rewriting the large console HTML.
# All API/admin routes from app.main remain untouched.
for route in list(app.router.routes):
    if getattr(route, "path", None) == "/" and "GET" in (getattr(route, "methods", set()) or set()):
        app.router.routes.remove(route)


@app.get("/", response_class=HTMLResponse)
def project5_console() -> HTMLResponse:
    html = (STATIC_DIR / "index.html").read_text(encoding="utf-8")
    marker = "</body>"
    overlay = '<script src="/static/runtime-overlay.js?v=20260906-1"></script>'
    if overlay not in html:
        html = html.replace(marker, overlay + "\n" + marker)
    return HTMLResponse(html, headers={"Cache-Control": "no-cache"})


def _safe_error() -> str | None:
    if not engine.load_error:
        return None
    # Do not expose the server's absolute project directory in browser diagnostics.
    return engine.load_error.replace(str(MODEL_PATH.parent.parent), ".")


def _file_state(path) -> dict:
    try:
        return {
            "name": path.name,
            "exists": path.exists(),
            "bytes": path.stat().st_size if path.exists() else 0,
        }
    except OSError as exc:
        return {"name": path.name, "exists": False, "bytes": 0, "error": str(exc)}


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
        "files": {
            "model": _file_state(MODEL_PATH),
            "voices": _file_state(VOICES_PATH),
            "config": _file_state(CONFIG_PATH),
        },
    }


@app.middleware("http")
async def project5_response_headers(request, call_next):
    """Small response-policy layer for the console and generated audio."""
    response = await call_next(request)
    path = request.url.path

    if path.startswith("/audio/"):
        filename = path.rsplit("/", 1)[-1]
        response.headers["Content-Disposition"] = f'inline; filename="{filename}"'
        response.headers["Cache-Control"] = "private, max-age=31536000, immutable"
        response.headers["X-Content-Type-Options"] = "nosniff"
    elif path == "/v1/voices":
        response.headers["Cache-Control"] = "public, max-age=86400, stale-while-revalidate=604800"
    elif path in {"/", "/runtime"}:
        response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"

    return response
