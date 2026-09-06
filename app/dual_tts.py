from __future__ import annotations

import re
import threading
import time
from pathlib import Path
from types import SimpleNamespace

from app.tts import CHINESE_VOICES, engine as kokoro_engine, voice_meta as kokoro_voice_meta

KOKORO_ENGINE = "kokoro"
EDGE_ENGINE = "edge"
SUPPORTED_ENGINES = (KOKORO_ENGINE, EDGE_ENGINE)

# Edge TTS is an online Microsoft Edge speech service accessed through the open-source
# rany2/edge-tts client. These are stable, commonly used Chinese voices. No model file
# is stored on this server for Edge TTS.
EDGE_VOICES = [
    {"id": "zh-CN-XiaoxiaoNeural", "label": "Edge 晓晓 · 普通话女声", "gender": "female", "locale": "zh-CN"},
    {"id": "zh-CN-XiaoyiNeural", "label": "Edge 晓伊 · 普通话女声", "gender": "female", "locale": "zh-CN"},
    {"id": "zh-CN-YunjianNeural", "label": "Edge 云健 · 普通话男声", "gender": "male", "locale": "zh-CN"},
    {"id": "zh-CN-YunxiNeural", "label": "Edge 云希 · 普通话男声", "gender": "male", "locale": "zh-CN"},
    {"id": "zh-CN-YunxiaNeural", "label": "Edge 云夏 · 普通话男声", "gender": "male", "locale": "zh-CN"},
    {"id": "zh-CN-YunyangNeural", "label": "Edge 云扬 · 普通话解说男声", "gender": "male", "locale": "zh-CN"},
    {"id": "zh-CN-liaoning-XiaobeiNeural", "label": "Edge 晓北 · 辽宁女声", "gender": "female", "locale": "zh-CN-liaoning"},
    {"id": "zh-CN-shaanxi-XiaoniNeural", "label": "Edge 晓妮 · 陕西女声", "gender": "female", "locale": "zh-CN-shaanxi"},
    {"id": "zh-TW-HsiaoChenNeural", "label": "Edge 晓臻 · 台湾女声", "gender": "female", "locale": "zh-TW"},
    {"id": "zh-TW-HsiaoYuNeural", "label": "Edge 晓雨 · 台湾女声", "gender": "female", "locale": "zh-TW"},
    {"id": "zh-TW-YunJheNeural", "label": "Edge 云哲 · 台湾男声", "gender": "male", "locale": "zh-TW"},
    {"id": "zh-HK-HiuGaaiNeural", "label": "Edge 晓佳 · 粤语女声", "gender": "female", "locale": "zh-HK"},
    {"id": "zh-HK-HiuMaanNeural", "label": "Edge 晓曼 · 粤语女声", "gender": "female", "locale": "zh-HK"},
    {"id": "zh-HK-WanLungNeural", "label": "Edge 云龙 · 粤语男声", "gender": "male", "locale": "zh-HK"},
]
EDGE_VOICE_IDS = {item["id"] for item in EDGE_VOICES}

DEFAULT_VOICES = {
    KOKORO_ENGINE: "zf_001",
    EDGE_ENGINE: "zh-CN-XiaoxiaoNeural",
}

_mixed_g2p_lock = threading.Lock()
_mixed_g2p_ready = False
_edge_metrics: dict = {}


def normalize_engine(engine_name: str | None, voice: str | None = None) -> str:
    """Resolve engine explicitly, while keeping old clients backward compatible."""
    raw = (engine_name or "").strip().lower()
    if voice in EDGE_VOICE_IDS or (voice or "").startswith(("zh-CN-", "zh-HK-", "zh-TW-")):
        return EDGE_ENGINE
    if raw in SUPPORTED_ENGINES:
        return raw
    return KOKORO_ENGINE


def default_voice(engine_name: str) -> str:
    return DEFAULT_VOICES[normalize_engine(engine_name)]


def is_valid_voice(engine_name: str, voice: str) -> bool:
    engine_name = normalize_engine(engine_name, voice)
    if engine_name == EDGE_ENGINE:
        return voice in EDGE_VOICE_IDS
    return voice in CHINESE_VOICES


def voice_list(engine_name: str | None = None) -> list[dict]:
    selected = (engine_name or "").strip().lower()
    result: list[dict] = []
    if selected in ("", KOKORO_ENGINE):
        for voice in CHINESE_VOICES:
            item = kokoro_voice_meta(voice)
            item.update({"engine": KOKORO_ENGINE, "model": "Kokoro-82M-v1.1-zh", "locale": "zh-CN"})
            result.append(item)
    if selected in ("", EDGE_ENGINE):
        for item in EDGE_VOICES:
            result.append({**item, "engine": EDGE_ENGINE, "model": "Microsoft Edge Online TTS"})
    return result


def model_name(engine_name: str) -> str:
    return "Microsoft Edge Online TTS" if engine_name == EDGE_ENGINE else "Kokoro-82M-v1.1-zh"


def audio_extension(engine_name: str) -> str:
    return ".mp3" if engine_name == EDGE_ENGINE else ".wav"


def _normalize_technical_english(text: str) -> str:
    """Make technical terms sound natural in Chinese knowledge/podcast content.

    CamelCase brands are separated into words and common all-caps abbreviations are
    spelled letter-by-letter. This happens only inside English spans already detected
    by Misaki's Chinese frontend.
    """
    text = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", text)
    text = re.sub(r"(?<=[A-Z])(?=[A-Z][a-z])", " ", text)
    # Acronyms in AI/engineering content are generally clearer as individual letters.
    text = re.sub(
        r"\b(?:AI|API|LLM|MCP|GPT|TTS|OCR|CPU|GPU|HTTP|HTTPS|URL|SQL|RAG|SDK|CLI|JSON|HTML|CSS)\b",
        lambda m: " ".join(m.group(0)),
        text,
        flags=re.IGNORECASE,
    )
    # Any remaining uppercase abbreviation of 2-6 letters is also spelled out.
    text = re.sub(r"\b[A-Z]{2,6}\b", lambda m: " ".join(m.group(0)), text)
    return re.sub(r"\s+", " ", text).strip()


def ensure_kokoro_mixed_g2p() -> None:
    """Install a lightweight English fallback into Misaki ZHG2P.

    Misaki ZHG2P(version='1.1') drops English spans when en_callable is None. We use
    Misaki's EspeakFallback instead of the heavy English spaCy/transformer stack, so
    mixed Chinese-English works without adding PyTorch/Transformers to the 8GB server.
    """
    global _mixed_g2p_ready
    if _mixed_g2p_ready:
        return

    kokoro_engine.load()
    with _mixed_g2p_lock:
        if _mixed_g2p_ready:
            return

        from misaki.espeak import EspeakFallback
        from misaki.zh import ZHG2P

        english_fallback = EspeakFallback(british=False, version="1.1")

        def english_callable(text: str) -> str:
            normalized = _normalize_technical_english(text)
            if not normalized:
                return ""
            phonemes, _ = english_fallback(SimpleNamespace(text=normalized))
            return phonemes or ""

        kokoro_engine.g2p = ZHG2P(version="1.1", en_callable=english_callable)
        # Clear any text cached before the mixed-language frontend was installed.
        cache_clear = getattr(kokoro_engine._phonemize_cached, "cache_clear", None)
        if callable(cache_clear):
            cache_clear()
        _mixed_g2p_ready = True
        kokoro_engine.load_metrics["mixed_zh_en"] = True
        kokoro_engine.load_metrics["english_frontend"] = "misaki-espeak-fallback"
        print("[Project5] Kokoro mixed Chinese-English G2P ready", flush=True)


def generate_kokoro(text: str, voice: str, speed: float, output_path: Path) -> float:
    ensure_kokoro_mixed_g2p()
    return kokoro_engine.generate(text, voice, speed, output_path)


def _edge_rate(speed: float) -> str:
    percent = int(round((float(speed) - 1.0) * 100))
    percent = max(-50, min(100, percent))
    return f"{percent:+d}%"


def generate_edge(text: str, voice: str, speed: float, output_path: Path) -> float:
    """Generate MP3 with Edge TTS, with short retry for transient online failures."""
    if voice not in EDGE_VOICE_IDS:
        raise ValueError(f"Unsupported Edge voice: {voice}")
    if not 0.5 <= float(speed) <= 2.0:
        raise ValueError("speed must be between 0.5 and 2.0")

    import edge_tts
    from mutagen.mp3 import MP3

    output_path.parent.mkdir(parents=True, exist_ok=True)
    rate = _edge_rate(speed)
    last_error: Exception | None = None
    started = time.perf_counter()

    for attempt in range(1, 4):
        output_path.unlink(missing_ok=True)
        try:
            communicate = edge_tts.Communicate(text, voice, rate=rate)
            communicate.save_sync(str(output_path))
            if not output_path.exists() or output_path.stat().st_size < 512:
                raise RuntimeError("Edge TTS returned an empty or incomplete MP3")
            duration = float(MP3(str(output_path)).info.length)
            elapsed = time.perf_counter() - started
            _edge_metrics.clear()
            _edge_metrics.update(
                {
                    "backend": "edge-tts-online",
                    "voice": voice,
                    "speed": float(speed),
                    "rate": rate,
                    "chars": len(text),
                    "total_ms": round(elapsed * 1000),
                    "audio_seconds": round(duration, 3),
                    "rtf": round(elapsed / duration, 3) if duration > 0 else None,
                    "attempt": attempt,
                }
            )
            print(
                f"[Project5][EDGE] voice={voice} chars={len(text)} rate={rate} "
                f"total={_edge_metrics['total_ms']}ms audio={duration:.2f}s attempt={attempt}",
                flush=True,
            )
            return round(duration, 3)
        except Exception as exc:
            last_error = exc
            if attempt < 3:
                time.sleep(attempt)

    output_path.unlink(missing_ok=True)
    assert last_error is not None
    raise RuntimeError(f"Edge TTS failed after 3 attempts: {type(last_error).__name__}: {last_error}")


def generate(engine_name: str, text: str, voice: str, speed: float, output_path: Path) -> float:
    selected = normalize_engine(engine_name, voice)
    if selected == EDGE_ENGINE:
        return generate_edge(text, voice, speed, output_path)
    return generate_kokoro(text, voice, speed, output_path)


def engine_metrics(engine_name: str) -> dict:
    if normalize_engine(engine_name) == EDGE_ENGINE:
        return dict(_edge_metrics)
    return dict(kokoro_engine.last_metrics)
