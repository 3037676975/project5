#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
import traceback
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUNTIME_REPO = ROOT / ".runtime" / "MeloTTS"
AUDIO_DIR = ROOT / "data" / "audio"
AUDIO_DIR.mkdir(parents=True, exist_ok=True)

if str(RUNTIME_REPO) not in sys.path:
    sys.path.insert(0, str(RUNTIME_REPO))

os.environ.setdefault("HF_HOME", str(ROOT / "models" / "melo-cache"))
os.environ.setdefault("TRANSFORMERS_CACHE", str(ROOT / "models" / "melo-cache" / "transformers"))
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

MODEL = None
MODEL_ERROR: str | None = None
MODEL_LOCK = threading.Lock()
SYNTH_LOCK = threading.Lock()
MODEL_LOADED_AT: float | None = None
SPEAKER_ID = None


def _json(handler: BaseHTTPRequestHandler, status: int, payload: dict) -> None:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def _duration(path: Path) -> float:
    with wave.open(str(path), "rb") as wav:
        frames = wav.getnframes()
        rate = wav.getframerate()
    return round(frames / rate, 3) if rate else 0.0


def ensure_model():
    global MODEL, MODEL_ERROR, MODEL_LOADED_AT, SPEAKER_ID
    if MODEL is not None:
        return MODEL
    with MODEL_LOCK:
        if MODEL is not None:
            return MODEL
        MODEL_ERROR = None
        try:
            import torch
            threads = max(1, int(os.getenv("MELO_THREADS", "4")))
            torch.set_num_threads(threads)
            try:
                torch.set_num_interop_threads(1)
            except RuntimeError:
                pass
            from melo.api import TTS
            started = time.perf_counter()
            model = TTS(language="ZH", device="cpu")
            speaker_ids = model.hps.data.spk2id
            # Follow MeloTTS's official API example exactly: speaker_ids['ZH'].
            # `spk2id` is an HParams object in the current upstream implementation,
            # so dict.get() is not available and caused our previous smoke-test failure.
            speaker = speaker_ids["ZH"]
            MODEL = model
            SPEAKER_ID = speaker
            MODEL_LOADED_AT = time.time()
            print(f"[Project5][Melo] model ready in {time.perf_counter()-started:.2f}s threads={threads}", flush=True)
            return MODEL
        except Exception as exc:
            MODEL_ERROR = f"{type(exc).__name__}: {exc}"
            print(f"[Project5][Melo] load failed: {MODEL_ERROR}", flush=True)
            traceback.print_exc()
            raise


class Handler(BaseHTTPRequestHandler):
    server_version = "Project5Melo/1.2"

    def log_message(self, fmt: str, *args) -> None:
        print("[Project5][Melo][HTTP] " + (fmt % args), flush=True)

    def do_GET(self) -> None:
        if self.path != "/health":
            _json(self, 404, {"error": "not found"})
            return
        _json(self, 200, {
            "status": "ready" if MODEL is not None else ("error" if MODEL_ERROR else "idle"),
            "service_ready": True,
            "model_loaded": MODEL is not None,
            "model_error": MODEL_ERROR,
            "model": "MeloTTS Chinese (ZH_MIX_EN)",
            "device": "cpu",
            "threads": max(1, int(os.getenv("MELO_THREADS", "4"))),
            "loaded_at": MODEL_LOADED_AT,
            "busy": SYNTH_LOCK.locked(),
        })

    def do_POST(self) -> None:
        if self.path != "/synthesize":
            _json(self, 404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 2_000_000:
                raise ValueError("invalid request size")
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            text = str(payload.get("text") or "").strip()
            voice = str(payload.get("voice") or "melo-zh")
            speed = float(payload.get("speed") or 1.0)
            filename = Path(str(payload.get("filename") or "")).name
            if not text:
                raise ValueError("text is empty")
            if voice != "melo-zh":
                raise ValueError("only melo-zh is supported")
            if not 0.5 <= speed <= 2.0:
                raise ValueError("speed must be between 0.5 and 2.0")
            if not filename.endswith(".wav") or not filename.startswith("tts_"):
                raise ValueError("invalid output filename")
            output = AUDIO_DIR / filename
            output.unlink(missing_ok=True)

            with SYNTH_LOCK:
                model = ensure_model()
                started = time.perf_counter()
                model.tts_to_file(text, SPEAKER_ID, str(output), speed=speed, quiet=True)
                if not output.exists() or output.stat().st_size <= 44:
                    raise RuntimeError("MeloTTS did not produce a valid WAV")
                duration = _duration(output)
                elapsed = time.perf_counter() - started
            _json(self, 200, {
                "ok": True,
                "filename": filename,
                "duration": duration,
                "bytes": output.stat().st_size,
                "elapsed_ms": round(elapsed * 1000),
                "model_loaded": MODEL is not None,
            })
        except Exception as exc:
            _json(self, 500, {"ok": False, "error": f"{type(exc).__name__}: {exc}"})


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=int(os.getenv("MELO_PORT", "8016")))
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    print(f"[Project5][Melo] service http://{args.host}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
