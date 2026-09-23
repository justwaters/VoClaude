"""Install the heavy speech dependencies on demand.

`uv tool install voclaude` only installs what `watch` and friends need.
`voclaude serve` calls `ensure()` to add PyTorch, Kokoro, faster-whisper
(and the CSM stack if configured) to its own environment the first time.
"""

from __future__ import annotations

import importlib.metadata
import importlib.util
import shutil
import subprocess
import sys

SPACY_MODEL = (
    "en_core_web_sm @ https://github.com/explosion/spacy-models/releases/download/"
    "en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"
)

# requirement → module to import-check
SPEECH = {
    "numpy": "numpy",
    "soundfile": "soundfile",
    "torch": "torch",
    "kokoro>=0.9.4": "kokoro",
    SPACY_MODEL: "en_core_web_sm",  # Kokoro's English G2P; fetched at runtime otherwise
}
STT = {"faster-whisper": "faster_whisper", "numpy": "numpy"}
CSM = {
    "numpy": "numpy",
    "soundfile": "soundfile",
    "torch": "torch",
    "torchaudio": "torchaudio",
    "transformers>=4.52.1": "transformers",
    "accelerate": "accelerate",
}


def required(cfg: dict) -> dict[str, str]:
    reqs: dict[str, str] = {}
    tts = cfg.get("tts", {})
    if tts.get("enabled", True):
        reqs.update(CSM if tts.get("engine", "kokoro") == "csm" else SPEECH)
    if cfg.get("stt", {}).get("enabled", True):
        reqs.update(STT)
    return reqs


def missing(reqs: dict[str, str]) -> list[str]:
    out = []
    for requirement, module in reqs.items():
        if importlib.util.find_spec(module) is None:
            out.append(requirement)
        elif module == "transformers" and _version_tuple("transformers") < (4, 52, 1):
            out.append(requirement)  # CSM support landed in 4.52.1
    return out


def install(requirements: list[str]) -> None:
    """Install into the interpreter running voclaude (the uv tool / venv environment)."""
    uv = shutil.which("uv")
    if uv:
        cmd = [uv, "pip", "install", "--python", sys.executable, *requirements]
    else:
        if importlib.util.find_spec("pip") is None:
            subprocess.run([sys.executable, "-m", "ensurepip", "--upgrade"], check=True)
        cmd = [sys.executable, "-m", "pip", "install", *requirements]
    subprocess.run(cmd, check=True)


def ensure(cfg: dict, echo=print) -> None:
    todo = missing(required(cfg))
    if not todo:
        return
    names = ", ".join(r.split(" @ ")[0] for r in todo)
    echo(f"Installing speech dependencies ({names}). This is a one-time download of a few GB…")
    install(todo)
    importlib.invalidate_caches()


def _version_tuple(dist: str) -> tuple[int, ...]:
    try:
        version = importlib.metadata.version(dist)
    except importlib.metadata.PackageNotFoundError:
        return (0,)
    parts = []
    for piece in version.split(".")[:3]:
        digits = "".join(ch for ch in piece if ch.isdigit())
        parts.append(int(digits or 0))
    return tuple(parts)
