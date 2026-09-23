import importlib
import sys
from pathlib import Path

import pytest


@pytest.fixture
def voclaude_home(tmp_path, monkeypatch):
    """Point VOCLAUDE_HOME at a temp dir and reload modules that read it at import."""
    monkeypatch.setenv("VOCLAUDE_HOME", str(tmp_path / "home"))
    monkeypatch.delenv("VOCLAUDE_TOKEN", raising=False)
    from voclaude import config

    importlib.reload(config)
    for name in ("voclaude.discovery", "voclaude.server", "voclaude.cli"):
        if name in sys.modules:
            importlib.reload(sys.modules[name])
    return Path(tmp_path / "home")


