from __future__ import annotations

from app.main import app


@app.middleware("http")
async def project5_response_headers(request, call_next):
    """Small response-policy layer for the console.

    Generated audio URLs are immutable task files, so browsers can safely cache
    them for a long time. They are served inline for HTML audio players; an <a
    download> link can still explicitly download the same URL. Voice metadata is
    also stable and receives a short public cache.
    """
    response = await call_next(request)
    path = request.url.path

    if path.startswith("/audio/"):
        filename = path.rsplit("/", 1)[-1]
        response.headers["Content-Disposition"] = f'inline; filename="{filename}"'
        response.headers["Cache-Control"] = "private, max-age=31536000, immutable"
        response.headers["X-Content-Type-Options"] = "nosniff"
    elif path == "/v1/voices":
        response.headers["Cache-Control"] = "public, max-age=86400, stale-while-revalidate=604800"
    elif path == "/":
        # The console itself is tiny; revalidate it so new GitHub deployments show
        # up quickly without forcing all immutable audio back through the network.
        response.headers["Cache-Control"] = "no-cache"

    return response
