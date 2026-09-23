"""Speech-to-text with faster-whisper for audio uploaded by the client."""

from __future__ import annotations

import logging
import threading

import numpy as np

log = logging.getLogger("voclaude.stt")

WHISPER_RATE = 16_000


class STTEngine:
    def __init__(self, cfg: dict):
        self.model_name: str = cfg.get("model", "base.en")
        self.device: str = cfg.get("device", "auto")
        self.compute_type: str = cfg.get("compute_type", "default")
        self.language: str | None = cfg.get("language")
        self._model = None
        self._load_lock = threading.Lock()
        self._run_lock = threading.Lock()

    def load(self) -> None:
        with self._load_lock:
            if self._model is not None:
                return
            from faster_whisper import WhisperModel

            log.info("Loading faster-whisper %s (%s, %s)…", self.model_name, self.device, self.compute_type)
            self._model = WhisperModel(self.model_name, device=self.device, compute_type=self.compute_type)
            log.info("faster-whisper ready")

    def transcribe(self, pcm16: bytes, sample_rate: int = WHISPER_RATE) -> str:
        """Transcribe little-endian 16-bit mono PCM. Blocking."""
        self.load()
        audio = np.frombuffer(pcm16, dtype="<i2").astype(np.float32) / 32768.0
        if sample_rate != WHISPER_RATE:
            audio = _resample(audio, sample_rate, WHISPER_RATE)
        if audio.size < WHISPER_RATE // 4:
            return ""
        with self._run_lock:
            segments, _ = self._model.transcribe(
                audio,
                language=self.language,
                beam_size=5,
                vad_filter=True,
            )
            return " ".join(seg.text.strip() for seg in segments).strip()


def _resample(audio: np.ndarray, src: int, dst: int) -> np.ndarray:
    # Linear interpolation is plenty for speech recognition input.
    n = int(round(audio.size * dst / src))
    return np.interp(np.linspace(0, audio.size - 1, n), np.arange(audio.size), audio).astype(np.float32)
