from __future__ import annotations

import os
import re
import threading
import time
from functools import lru_cache
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parent.parent
REPO_ID = "hexgrad/Kokoro-82M-v1.1-zh"
SAMPLE_RATE = 24000
MODEL_PATH = Path(os.getenv("KOKORO_ONNX_MODEL", ROOT / "models" / "kokoro-v1.1-zh.int8.onnx"))
VOICES_PATH = Path(os.getenv("KOKORO_ONNX_VOICES", ROOT / "models" / "voices-v1.1-zh.bin"))
CONFIG_PATH = Path(os.getenv("KOKORO_ONNX_CONFIG", ROOT / "models" / "config.json"))

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
    """CPU-optimized Kokoro-82M-v1.1-zh inference engine.

    The model stays resident in memory for the lifetime of the Uvicorn process.
    ONNX Runtime gets an explicit CPU session configuration instead of relying on
    platform defaults, and a short warm-up inference is performed at startup so
    the first real browser/API request does not pay graph/kernel initialization.
    """

    def __init__(self) -> None:
        self.model = None
        self.g2p = None
        self.loaded = False
        self.loading = False
        self.load_error: str | None = None
        self.device = "cpu"
        self.backend = "onnx-int8"
        requested_threads = int(os.getenv("KOKORO_THREADS", str(min(8, os.cpu_count() or 4))))
        self.threads = max(1, min(requested_threads, os.cpu_count() or requested_threads))
        self.last_metrics: dict = {}
        self.load_metrics: dict = {}
        self._load_lock = threading.Lock()

    def load(self) -> None:
        if self.loaded:
            return

        with self._load_lock:
            if self.loaded:
                return
            self.loading = True
            self.load_error = None
            started = time.perf_counter()
            print(
                f"[Project5] Loading Kokoro ONNX INT8: {MODEL_PATH} "
                f"threads={self.threads}",
                flush=True,
            )
            try:
                missing = [str(path) for path in (MODEL_PATH, VOICES_PATH, CONFIG_PATH) if not path.exists()]
                if missing:
                    raise FileNotFoundError(
                        "Kokoro ONNX files are missing: " + ", ".join(missing) + ". Run scripts/auto-deploy.sh."
                    )

                # Keep CPU scheduling predictable on small cloud VMs.
                os.environ["OMP_NUM_THREADS"] = str(self.threads)
                os.environ["OMP_WAIT_POLICY"] = "ACTIVE"
                os.environ["ORT_NUM_THREADS"] = str(self.threads)

                import onnxruntime as ort
                from kokoro_onnx import Kokoro
                from misaki import zh

                options = ort.SessionOptions()
                options.intra_op_num_threads = self.threads
                options.inter_op_num_threads = 1
                options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
                options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
                options.enable_cpu_mem_arena = True
                options.enable_mem_pattern = True
                try:
                    options.add_session_config_entry("session.intra_op.allow_spinning", "1")
                except Exception:
                    pass

                session_started = time.perf_counter()
                session = ort.InferenceSession(
                    str(MODEL_PATH),
                    sess_options=options,
                    providers=["CPUExecutionProvider"],
                )
                session_seconds = time.perf_counter() - session_started

                self.g2p = zh.ZHG2P(version="1.1")
                self.model = Kokoro.from_session(
                    session,
                    str(VOICES_PATH),
                    vocab_config=str(CONFIG_PATH),
                )

                # Warm up the exact Chinese path used by normal requests. This cost is
                # paid once at process start instead of on the first user click.
                warm_started = time.perf_counter()
                warm_phonemes, _ = self.g2p("你好，这是语音服务预热。")
                self.model.create(
                    warm_phonemes,
                    voice="zf_001",
                    speed=1.0,
                    is_phonemes=True,
                )
                warm_seconds = time.perf_counter() - warm_started

                self.loaded = True
                total_seconds = time.perf_counter() - started
                self.load_metrics = {
                    "backend": self.backend,
                    "threads": self.threads,
                    "session_ms": round(session_seconds * 1000),
                    "warmup_ms": round(warm_seconds * 1000),
                    "total_ms": round(total_seconds * 1000),
                }
                print(
                    "[Project5] Kokoro ONNX ready: "
                    f"session={session_seconds:.2f}s warmup={warm_seconds:.2f}s "
                    f"total={total_seconds:.2f}s threads={self.threads}",
                    flush=True,
                )
            except Exception as exc:
                self.load_error = f"{type(exc).__name__}: {exc}"
                print(f"[Project5] Kokoro ONNX load failed: {self.load_error}", flush=True)
                raise
            finally:
                self.loading = False

    def start_background_load(self) -> None:
        if self.loaded or self.loading:
            return
        threading.Thread(target=self._background_load, name="kokoro-onnx-preload", daemon=True).start()

    def _background_load(self) -> None:
        try:
            self.load()
        except Exception:
            pass

    @staticmethod
    def _split_text(text: str, max_chars: int = 220) -> Iterable[str]:
        """Split long Chinese text at punctuation while keeping short requests in one inference."""
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

    @lru_cache(maxsize=512)
    def _phonemize_cached(self, text: str) -> str:
        if self.g2p is None:
            raise RuntimeError("Chinese G2P is not loaded")
        phonemes, _ = self.g2p(text)
        return phonemes

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

        total_started = time.perf_counter()
        g2p_seconds = 0.0
        inference_seconds = 0.0
        write_seconds = 0.0
        audio_parts = []
        sample_rate = SAMPLE_RATE

        for index, chunk in enumerate(chunks):
            g2p_started = time.perf_counter()
            phonemes = self._phonemize_cached(chunk)
            g2p_seconds += time.perf_counter() - g2p_started

            infer_started = time.perf_counter()
            samples, sample_rate = self.model.create(
                phonemes,
                voice=voice,
                speed=float(speed),
                is_phonemes=True,
            )
            inference_seconds += time.perf_counter() - infer_started

            audio = np.asarray(samples, dtype=np.float32).reshape(-1)
            if not audio.size:
                continue
            if index and audio_parts:
                audio_parts.append(np.zeros(int(sample_rate * 0.12), dtype=np.float32))
            audio_parts.append(audio)

        if not audio_parts:
            raise RuntimeError("Kokoro ONNX returned no audio")

        wav = np.concatenate(audio_parts)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        write_started = time.perf_counter()
        sf.write(str(output_path), wav, sample_rate, subtype="PCM_16")
        write_seconds = time.perf_counter() - write_started

        duration = len(wav) / sample_rate
        total_seconds = time.perf_counter() - total_started
        rtf = total_seconds / duration if duration > 0 else 0.0
        self.last_metrics = {
            "chars": len(text),
            "voice": voice,
            "speed": float(speed),
            "threads": self.threads,
            "g2p_ms": round(g2p_seconds * 1000),
            "inference_ms": round(inference_seconds * 1000),
            "write_ms": round(write_seconds * 1000),
            "total_ms": round(total_seconds * 1000),
            "audio_seconds": round(duration, 3),
            "rtf": round(rtf, 3),
            "backend": self.backend,
        }
        print(
            "[Project5][TTS] "
            f"voice={voice} chars={len(text)} threads={self.threads} "
            f"g2p={self.last_metrics['g2p_ms']}ms "
            f"infer={self.last_metrics['inference_ms']}ms "
            f"write={self.last_metrics['write_ms']}ms "
            f"total={self.last_metrics['total_ms']}ms "
            f"audio={duration:.2f}s rtf={rtf:.3f}",
            flush=True,
        )
        return round(duration, 3)


engine = KokoroEngine()
# Model and voices are local files. Preload and warm up once in the background.
engine.start_background_load()
