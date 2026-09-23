"""User configuration: ~/.config/voclaude/config.json (override the directory with VOCLAUDE_HOME)."""

from __future__ import annotations

import copy
import json
import os
import re
import subprocess
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("VOCLAUDE_HOME") or Path.home() / ".config" / "voclaude").expanduser()
CONFIG_PATH = CONFIG_DIR / "config.json"
STATE_PATH = CONFIG_DIR / "state.json"

DEFAULT_CONFIG: dict = {
    "host": "0.0.0.0",
    "port": 8000,
    "auth_token": "",
    "discovery": True,  # advertise on Bonjour so the app can find this daemon
    "claude": {
        "bin": "claude",
        "allowed_tools": ["Read", "Edit", "Bash"],
        "permission_mode": None,
        "extra_args": [],
    },
    "repos": {},
    "tts": {
        "enabled": True,
        "engine": "kokoro",
        "preload": True,
        "kokoro": {
            "voice": "af_heart",
            "voices": ["af_heart", "bf_emma", "am_puck", "bm_george"],
            "speed": 1.0,
            "device": "cpu",
        },
        "csm": {
            "model_id": "sesame/csm-1b",
            "device": "auto",
            "dtype": "auto",
            "speaker_id": 0,
            "seed": 42,
            "voice_prompt": {"audio_path": None, "text": None},
            "max_audio_seconds": 20,
        },
    },
    "stt": {
        "enabled": True,
        "model": "base.en",
        "device": "auto",
        "compute_type": "default",
        "language": "en",
        "preload": False,
    },
}


def load(path: Path = CONFIG_PATH) -> dict:
    """Read the config, creating it with defaults on first use.

    Keys missing from the file are filled from DEFAULT_CONFIG, so older
    configs keep working as settings are added.
    """
    if not path.exists():
        save(DEFAULT_CONFIG, path)
    user = json.loads(path.read_text())
    return _merge(DEFAULT_CONFIG, user)


def save(cfg: dict, path: Path = CONFIG_PATH) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(cfg, indent=2) + "\n")
    tmp.replace(path)


def _merge(defaults: dict, user: dict) -> dict:
    merged = copy.deepcopy(defaults)
    for key, value in user.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict) and key != "repos":
            merged[key] = _merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def repo_root(path: Path) -> Path:
    """The enclosing git repository's root, or `path` itself outside git."""
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=path, capture_output=True, text=True, check=True,
        ).stdout.strip()
        return Path(out).resolve()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return path.resolve()


def slugify(name: str) -> str:
    slug = re.sub(r"[^a-z0-9_-]+", "-", name.lower()).strip("-_")
    return slug or "repo"


def watch(path: Path, alias: str | None = None, display_name: str | None = None,
          config_path: Path = CONFIG_PATH) -> tuple[str, bool]:
    """Add the repo containing `path` to the watched repos.

    Returns (alias, added). `added` is False if the repo was already watched.
    """
    root = repo_root(path)
    raw = json.loads(config_path.read_text()) if config_path.exists() else copy.deepcopy(DEFAULT_CONFIG)
    repos: dict = raw.setdefault("repos", {})

    for existing_alias, repo in repos.items():
        if Path(repo["path"]).expanduser().resolve() == root:
            if alias and alias != existing_alias:
                raise ValueError(f"{root} is already watched as '{existing_alias}'")
            return existing_alias, False

    if alias:
        alias = slugify(alias)
        if alias in repos:
            raise ValueError(f"The alias '{alias}' is already used by {repos[alias]['path']}")
    else:
        base = slugify(root.name)
        alias, n = base, 2
        while alias in repos:
            alias, n = f"{base}-{n}", n + 1

    repos[alias] = {"display_name": display_name or root.name, "path": str(root)}
    save(raw, config_path)
    return alias, True


def unwatch(target: str | Path, config_path: Path = CONFIG_PATH) -> str | None:
    """Stop watching a repo, given its alias or a path inside it. Returns the removed alias."""
    if not config_path.exists():
        return None
    raw = json.loads(config_path.read_text())
    repos: dict = raw.get("repos", {})
    alias = str(target) if str(target) in repos else None
    if alias is None:
        root = repo_root(Path(target))
        alias = next(
            (a for a, r in repos.items() if Path(r["path"]).expanduser().resolve() == root), None
        )
    if alias is None:
        return None
    del repos[alias]
    save(raw, config_path)
    return alias


def resolve_token(cfg: dict) -> str:
    """The daemon's auth token: $VOCLAUDE_TOKEN, config `auth_token`, or a generated one kept in state.json.

    The daemon can run Bash in your repos, so it never serves without a token.
    """
    import secrets

    from .session_manager import StateStore

    token = os.environ.get("VOCLAUDE_TOKEN") or cfg.get("auth_token")
    if token:
        return token
    state = StateStore(STATE_PATH)
    token = state.get("auth_token")
    if not token:
        token = secrets.token_urlsafe(24)
        state.set("auth_token", token)
    return token
