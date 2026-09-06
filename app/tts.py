from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Iterable

REPO_ID = os.getenv("KOKORO_REPO_ID", "hexgrad/Kokoro-82M-v1.1-zh")
SAMPLE_RATE = 24000

# Kokoro-82M-v1.1-zh Chinese voices. zf = female, zm = male.
CHINESE_VOICES = [
    "zf_001", "zf_002", "zf_003", "zf_004", "zf_005", "zf_006", "zf_007", "zf_008",
    "zf_017", "zf_018", "zf_019", "zf_021", "zf_022", "zf_023", "zf_024", "zf_026",
    "zf_027", "zf_028", "zf_032", "zf_036", "zf_038", "zf_039", "zf_040", "zf_042",
    "zf_043", "zf_044", "zf_046", "zf_047", "zf_048", "zf_049", "zf_051", "zf_059",
    "zf_060", "zf_067", "zf_070", "zf_071", "zf_072", "zf_073", "zf_074", "zf_075",
    "zf_076", "zf_077", "zf_078", "zf_079", "zf_083", "zf_084", "zf_085", "zf_086",
    "zf_087", "zf_088", "zf_090", "zf_092", "zf_093", "zf_094", "zf_099",
    "zm_009", "zm_010", "zm_011", "zm_012", "zm_013", "zm_014", "zm_015", "zm_016",
    "zm_020", "zm_025", "zm_029", "zm_030", "zm_031", "zm_033", "zm_034", "zm_035",
    "zm_037", "zm_041", "zm_045", "zm_050", "zm_052", "zm_053", "zm_054", "zm_055",
    "zm_056", "zm_057", "zm_058", "zm_061", "zm_062", "zm_063", "zm_064", "zm_065",
    "zm_066", "zm_068", "zm_069", "zm_080", "zm_081", "zm_082", "zm_089", "zm_091",
    "zm_095", "zm_096", "zm_097", "zm_098", "zm_100",
]


def voice_meta(voice: str) -> dict:
    return {
        "id": voice,
        "gender": "female" if voice.startswith("zf_") else "male",
        "label": ("中文女声 " if voice.startswith("zf_") else "中文男声 ") + voice.split("_")[1],
    }


class KokoroEngine:
    """Lazy-loaded, single-model Kokoro inference engine.

    The process intentionally keeps one model instance in memory. Project5 runs one
    uvicorn worker by default so an 8 GB CPU server does not load duplicate models.
    """

    def __init__(self) -> None:
        self.model = None
        self.pipeline = None
        self.en_pipeline = None
        self.loaded = False
        self.device = os.getenv("KOKORO_DEVICE", "cpu")

    def load(self) -> None:
        if self.loaded:
            return

        import torch
        from kokoro import KModel, KPipeline

        threads = int(os.getenv("KOKORO_THREADS", str(min(8, os.cpu_count() or 4))))
        if self.device == "cpu":
            torch.set_num_threads(max(1, threads))

        self.model = KModel(repo_id=REPO_ID).to(self.device).eval()
        # Official v1.1-zh sample uses an English pipeline as the callable for
        # Latin/English fragments inside Chinese sentences.
        self.en_pipeline = KPipeline(lang_code="a", repo_id=REPO_ID, model=False)

        def en_callable(text: str) -> str:
            result = next(self.en_pipeline(text))
            return result.phonemes

        self.pipeline = KPipeline(
            lang_code="z",
            repo_id=REPO_ID,
            model=self.model,
            en_callable=en_callable,
        )
        self.loaded = True

    @staticmethod
    def _split_text(text: str, max_chars: int = 180) -> Iterable[str]:
        """Split long Chinese text at punctuation to keep pronunciation stable."""
        text = re.sub(r"\s+", " ", text).strip()
        if len(text) <= max_chars:
            yield text
            return

        parts = re.split(r"(?<=[。！？!?；;，,、\n])", text)
        current = ""
        for part in parts:
            if not part:
                continue
            if len(current) + len(part) <= max_chars:
                current += part
                continue
            if current.strip():
                yield current.strip()
            while len(part) > max_chars:
                yield part[:max_chars].strip()
                part = part[max_chars:]
            current = part
        if current.strip():
            yield current.strip()

    def generate(self, text: str, voice: str, speed: float, output_path: Path) -> float:
        if voice not in CHINESE_VOICES:
            raise ValueError(f"Unsupported voice: {voice}")
        if not 0.5 <= speed <= 2.0:
            raise ValueError("speed must be between 0.5 and 2.0")

        self.load()

        import numpy as np
        import soundfile as sf

        chunks = list(self._split_text(text))
        if not chunks:
            raise ValueError("input text is empty")

        audio_parts = []
        silence = np.zeros(int(SAMPLE_RATE * 0.12), dtype=np.float32)
        for index, chunk in enumerate(chunks):
            generator = self.pipeline(chunk, voice=voice, speed=float(speed))
            chunk_parts = []
            for result in generator:
                audio = result.audio
                if hasattr(audio, "detach"):
                    audio = audio.detach().cpu().numpy()
                audio = np.asarray(audio, dtype=np.float32).reshape(-1)
                if audio.size:
                    chunk_parts.append(audio)
            if not chunk_parts:
                continue
            if index and audio_parts:
                audio_parts.append(silence)
            audio_parts.extend(chunk_parts)

        if not audio_parts:
            raise RuntimeError("Kokoro returned no audio")

        wav = np.concatenate(audio_parts)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        sf.write(str(output_path), wav, SAMPLE_RATE, subtype="PCM_16")
        return round(len(wav) / SAMPLE_RATE, 3)


engine = KokoroEngine()
