"""Text-to-speech with Sesame's CSM (sesame/csm-1b) via Hugging Face transformers.

Also contains the helpers that turn Claude's streamed markdown into speakable
sentence-sized chunks.
"""

from __future__ import annotations

import logging
import re
import threading
from pathlib import Path

import numpy as np

log = logging.getLogger("voclaude.csm")

SAMPLE_RATE = 24_000  # CSM / Mimi output rate
FRAME_RATE = 12.5  # Mimi codec frames per second; one generated token per frame


class CSMEngine:
    """Thread-safe wrapper around CsmForConditionalGeneration.

    The model is loaded lazily on first use (or eagerly via `load()`), and
    generation is serialized because one model instance is shared by every
    WebSocket connection.

    CSM picks a random voice for each un-conditioned generation. To keep one
    consistent voice across sentences, every request is conditioned on a
    reference clip: `voice_prompt` from config if provided, otherwise the first
    sentence this engine ever generated.
    """

    sample_rate = SAMPLE_RATE
    default_voice = None

    def __init__(self, cfg: dict, base_dir: Path):
        self.model_id: str = cfg.get("model_id", "sesame/csm-1b")
        self.speaker_id: int = int(cfg.get("speaker_id", 0))
        self.seed: int | None = cfg.get("seed")
        self.max_audio_seconds: float = float(cfg.get("max_audio_seconds", 20))
        self._device_pref: str = cfg.get("device", "auto")
        self._dtype_pref: str = cfg.get("dtype", "auto")

        vp = cfg.get("voice_prompt") or {}
        self._voice_prompt_path = (base_dir / vp["audio_path"]).expanduser() if vp.get("audio_path") else None
        self._voice_prompt_text: str | None = vp.get("text")

        self._load_lock = threading.Lock()
        self._gen_lock = threading.Lock()
        self._model = None
        self._processor = None
        self._device = None
        self._anchor: tuple[str, np.ndarray] | None = None
        self.load_error: Exception | None = None

    @property
    def loaded(self) -> bool:
        return self._model is not None

    def voice_options(self) -> list[dict]:
        return []  # one voice, set by voice_prompt

    def resolve_voice(self, requested: str | None) -> None:
        return None

    def load(self) -> None:
        with self._load_lock:
            if self._model is not None:
                return
            if self.load_error is not None:
                raise RuntimeError(f"CSM failed to load: {self.load_error}") from self.load_error
            try:
                self._load()
            except Exception as exc:
                self.load_error = exc
                raise

    def _load(self) -> None:
        import torch
        import transformers
        from transformers import AutoProcessor, CsmForConditionalGeneration

        device = _pick_device(self._device_pref)
        dtype = _pick_dtype(self._dtype_pref, device)
        log.info("Loading %s on %s (%s)…", self.model_id, device, dtype)

        # transformers v5 renamed `torch_dtype` to `dtype`.
        dtype_kw = "dtype" if int(transformers.__version__.split(".")[0]) >= 5 else "torch_dtype"
        processor = AutoProcessor.from_pretrained(self.model_id)
        model = CsmForConditionalGeneration.from_pretrained(self.model_id, **{dtype_kw: dtype})
        model.to(device).eval()

        if self._voice_prompt_path:
            if not self._voice_prompt_text:
                raise ValueError("tts.voice_prompt.text is required when audio_path is set")
            self._anchor = (self._voice_prompt_text, _load_wav(self._voice_prompt_path))
            log.info("Using voice prompt %s", self._voice_prompt_path)

        self._processor, self._model, self._device = processor, model, device
        log.info("CSM ready")

    def synthesize(self, text: str, voice: str | None = None) -> np.ndarray:
        """Generate mono float32 audio at SAMPLE_RATE for `text`. Blocking."""
        import torch

        self.load()
        with self._gen_lock:
            conversation = []
            if self._anchor is not None:
                anchor_text, anchor_audio = self._anchor
                conversation.append({
                    "role": str(self.speaker_id),
                    "content": [
                        {"type": "text", "text": anchor_text},
                        {"type": "audio", "path": anchor_audio},
                    ],
                })
            conversation.append({"role": str(self.speaker_id), "content": [{"type": "text", "text": text}]})

            inputs = self._processor.apply_chat_template(conversation, tokenize=True, return_dict=True)
            inputs = inputs.to(self._device)
            if self._model.dtype != torch.float32 and "input_values" in inputs:
                inputs["input_values"] = inputs["input_values"].to(self._model.dtype)

            if self.seed is not None:
                torch.manual_seed(self.seed)
            with torch.inference_mode():
                audio = self._model.generate(
                    **inputs,
                    output_audio=True,
                    max_new_tokens=self._max_new_tokens(text),
                )
            wav = audio[0].detach().float().cpu().numpy().reshape(-1)
            peak = float(np.abs(wav).max(initial=0.0))
            if peak > 0.99:
                # CSM occasionally overshoots full scale; scale down instead of hard-clipping.
                wav = wav * (0.95 / peak)

            if self._anchor is None:
                # Lock in this voice for every later sentence.
                self._anchor = (text, wav.copy())
            return wav

    def _max_new_tokens(self, text: str) -> int:
        # ~15 characters of English per second of speech; allow 2x headroom.
        seconds = min(self.max_audio_seconds, max(3.0, len(text) / 15 * 2))
        return int(seconds * FRAME_RATE)


def _pick_device(pref: str) -> str:
    import torch

    if pref != "auto":
        return pref
    if torch.cuda.is_available():
        return "cuda"
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def _pick_dtype(pref: str, device: str):
    import torch

    if pref != "auto":
        return getattr(torch, pref)
    return torch.bfloat16 if device == "cuda" and torch.cuda.is_bf16_supported() else torch.float32


def _load_wav(path: Path) -> np.ndarray:
    import soundfile as sf
    import torch
    import torchaudio.functional as AF

    data, sr = sf.read(str(path), dtype="float32", always_2d=True)
    mono = data.mean(axis=1)
    if sr != SAMPLE_RATE:
        mono = AF.resample(torch.from_numpy(mono), sr, SAMPLE_RATE).numpy()
    return mono


def to_pcm16(wav: np.ndarray) -> bytes:
    return (np.clip(wav, -1.0, 1.0) * 32767.0).astype("<i2").tobytes()


# --- Markdown → speakable sentences ------------------------------------------------

_FENCE = "```"
_BOUNDARY = re.compile(r"[.!?]+[\"')\]]*(?=\s)|\n")
_LINK = re.compile(r"\[([^\]]+)\]\([^)]+\)")
_URL = re.compile(r"https?://\S+")
_MARKUP = re.compile(r"^\s*(#{1,6}|[-*+]|\d+\.|>)\s+")
_SNAKE = re.compile(r"(?<=[A-Za-z0-9])_(?=[A-Za-z0-9])")
_EMPHASIS = re.compile(r"[*_`~]+")
_TABLE = re.compile(r"^\s*\|.*\|\s*$")


def clean_for_speech(text: str) -> str:
    """Strip markdown syntax so the TTS model reads prose, not punctuation."""
    if _TABLE.match(text):
        return ""
    text = _LINK.sub(r"\1", text)
    text = _URL.sub("a link", text)
    text = _MARKUP.sub("", text)
    text = _SNAKE.sub(" ", text)
    text = _EMPHASIS.sub("", text)
    text = " ".join(text.split())
    return text if re.search(r"[A-Za-z0-9]", text) else ""


class SentenceChunker:
    """Accumulates streamed text deltas and emits speakable chunks.

    Splits on sentence ends and newlines, skips fenced code blocks entirely,
    and merges short fragments so each TTS call carries a reasonable phrase.
    """

    def __init__(self, min_chars: int = 40, max_chars: int = 300):
        self.min_chars = min_chars
        self.max_chars = max_chars
        self._buf = ""
        self._pending = ""
        self._in_code = False

    def feed(self, delta: str) -> list[str]:
        self._buf += delta
        out: list[str] = []
        while True:
            if self._in_code:
                end = self._buf.find(_FENCE)
                if end < 0:
                    # Keep a tail in case a closing fence is split across deltas.
                    self._buf = self._buf[-2:]
                    break
                nl = self._buf.find("\n", end + 3)
                if nl < 0:
                    break  # wait for the rest of the fence line
                self._buf = self._buf[nl + 1:]
                self._in_code = False
                continue

            fence = self._buf.find(_FENCE)
            match = _BOUNDARY.search(self._buf)
            if fence >= 0 and (match is None or fence < match.start()):
                self._add(self._buf[:fence], out)
                self._buf = self._buf[fence + 3:]
                self._in_code = True
                continue
            if match is None:
                if len(self._buf) > self.max_chars:
                    # No boundary in sight; break at the last space.
                    cut = self._buf.rfind(" ", 0, self.max_chars)
                    cut = cut if cut > 0 else self.max_chars
                    self._add(self._buf[:cut], out)
                    self._buf = self._buf[cut:]
                    continue
                break
            self._add(self._buf[: match.end()], out)
            self._buf = self._buf[match.end():]
        return out

    def flush(self) -> list[str]:
        out: list[str] = []
        if not self._in_code:
            self._add(self._buf, out)
        self._buf = ""
        self._in_code = False
        if self._pending:
            out.append(self._pending)
            self._pending = ""
        return out

    def _add(self, fragment: str, out: list[str]) -> None:
        cleaned = clean_for_speech(fragment)
        if not cleaned:
            return
        self._pending = f"{self._pending} {cleaned}".strip()
        if len(self._pending) >= self.min_chars:
            out.append(self._pending)
            self._pending = ""
