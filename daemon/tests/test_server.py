import pytest
from fastapi.testclient import TestClient

from pathlib import Path

FAKE_CLAUDE = str(Path(__file__).with_name("fake_claude.py"))


@pytest.fixture
def client(voclaude_home, tmp_path):
    from voclaude import config, server

    repo = tmp_path / "repo"
    repo.mkdir()
    cfg = config.load()
    cfg.update(auth_token="t0ken", discovery=False)
    cfg["claude"]["bin"] = FAKE_CLAUDE
    cfg["tts"]["enabled"] = False
    cfg["stt"]["enabled"] = False
    config.save(cfg)
    config.watch(repo, alias="demo")

    with TestClient(server.create_app(server.Daemon(config.load()))) as c:
        yield c, repo


def run_turn(ws, content):
    ws.send_json({"type": "text", "content": content})
    events = []
    while True:
        event = ws.receive_json()
        events.append(event)
        if event == {"type": "status", "state": "done"}:
            return events


def test_rejects_bad_token(client):
    c, _ = client
    assert c.get("/sessions").status_code == 401
    with pytest.raises(Exception):
        with c.websocket_connect("/ws/session/demo?token=wrong") as ws:
            ws.receive_json()


def test_turn_streams_and_resumes(client):
    c, _ = client
    with c.websocket_connect("/ws/session/demo", headers={"Authorization": "Bearer t0ken"}) as ws:
        hello = ws.receive_json()
        assert hello["type"] == "session" and hello["session_id"] is None

        events = run_turn(ws, "hello")
        text = "".join(e["content"] for e in events if e["type"] == "text")
        assert text == "You said: hello. Done."
        assert {"type": "tool", "name": "Bash", "summary": "ls -la"} in events
        first = next(e for e in events if e["type"] == "result")["session_id"]

        second = next(e for e in run_turn(ws, "again") if e["type"] == "result")["session_id"]
        assert second == first  # resumed with --resume


def test_watch_while_running_is_picked_up(client, tmp_path):
    from voclaude import config

    c, _ = client
    other = tmp_path / "other"
    other.mkdir()
    config.watch(other)
    aliases = {r["alias"] for r in c.get("/sessions", headers={"Authorization": "Bearer t0ken"}).json()}
    assert aliases == {"demo", "other"}
