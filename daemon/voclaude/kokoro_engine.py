"""Lightweight text-to-speech with Kokoro-82M (hexgrad/Kokoro-82M).

Runs faster than real time on a plain CPU (macOS or Linux), so it's the default
engine. Voices are fixed presets; the voice is chosen per request.
"""

from __future__ import annotations

import logging
import threading

import numpy as np

log = logging.getLogger("voclaude.kokoro")

SAMPLE_RATE = 24_000
REPO_ID = "hexgrad/Kokoro-82M"

# Friendly names shown in the client. Kokoro voice IDs encode accent and gender:
# a = American, b = British; f = female, m = male.
VOICE_LABELS = {
    "af_heart": "Heart (American, female)",
    "bf_emma": "Emma (British, female)",
    "am_puck": "Puck (American, male)",
    "bm_george": "George (British, male)",
}
DEFAULT_VOICES = list(VOICE_LABELS)


class KokoroEngine:
    """Thread-safe Kokoro wrapper sharing one model across all voices and connections."""

    sample_rate = SAMPLE_RATE

    def __init__(self, cfg: dict):
        self.voices: list[str] = cfg.get("voices") or DEFAULT_VOICES
        self.default_voice: str = cfg.get("voice") or self.voices[0]
        if self.default_voice not in self.voices:
            self.voices.insert(0, self.default_voice)
        self.speed: float = float(cfg.get("speed", 1.0))
        self._device: str = cfg.get("device", "cpu")

        self._load_lock = threading.Lock()
        self._gen_lock = threading.Lock()
        self._model = None
        self._pipelines: dict[str, object] = {}  # lang code → G2P pipeline
        self.load_error: Exception | None = None

    @property
    def loaded(self) -> bool:
        return self._model is not None

    def voice_options(self) -> list[dict]:
        return [{"id": v, "name": VOICE_LABELS.get(v, v)} for v in self.voices]

    def resolve_voice(self, requested: str | None) -> str:
        return requested if requested in self.voices else self.default_voice

    def load(self) -> None:
        with self._load_lock:
            if self._model is not None:
                return
            if self.load_error is not None:
                raise RuntimeError(f"Kokoro failed to load: {self.load_error}") from self.load_error
            try:
                from kokoro import KModel, KPipeline

                log.info("Loading Kokoro-82M on %s…", self._device)
                model = KModel(repo_id=REPO_ID).to(self._device).eval()
                # Pipelines only do text → phonemes; they share the single model above.
                for lang in sorted({v[0] for v in self.voices}):
                    pipeline = KPipeline(lang_code=lang, repo_id=REPO_ID, model=False)
                    for voice in self.voices:
                        if voice[0] == lang:
                            pipeline.load_voice(voice)  # fetch now, not mid-conversation
                    self._pipelines[lang] = pipeline
                self._model = model
                log.info("Kokoro ready (voices: %s)", ", ".join(self.voices))
            except Exception as exc:
                self.load_error = exc
                raise

    def synthesize(self, text: str, voice: str | None = None) -> np.ndarray:
        """Generate mono float32 audio at SAMPLE_RATE. Blocking."""
        self.load()
        voice = self.resolve_voice(voice)
        pipeline = self._pipelines[voice[0]]
        with self._gen_lock:
            chunks = [
                np.asarray(result.audio, dtype=np.float32)
                for result in pipeline(text, voice=voice, speed=self.speed, model=self._model)
                if result.audio is not None
            ]
        return np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.float32)
