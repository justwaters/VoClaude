import json
import subprocess


def test_watch_adds_git_root_once(voclaude_home, tmp_path):
    from voclaude import config

    repo = tmp_path / "My Project"
    (repo / "src").mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(repo)], check=True)

    alias, added = config.watch(repo / "src")  # from a subdirectory
    assert (alias, added) == ("my-project", True)
    assert config.load()["repos"]["my-project"] == {"display_name": "My Project", "path": str(repo.resolve())}

    assert config.watch(repo) == ("my-project", False)


def test_watch_dedupes_aliases_and_unwatch(voclaude_home, tmp_path):
    from voclaude import config

    a, b = tmp_path / "a" / "app", tmp_path / "b" / "app"
    a.mkdir(parents=True)
    b.mkdir(parents=True)
    assert config.watch(a)[0] == "app"
    assert config.watch(b)[0] == "app-2"

    assert config.unwatch("app") == "app"
    assert config.unwatch(b) == "app-2"
    assert config.load()["repos"] == {}
    assert config.unwatch("nope") is None


def test_load_fills_new_defaults(voclaude_home):
    from voclaude import config

    config.CONFIG_PATH.parent.mkdir(parents=True)
    config.CONFIG_PATH.write_text(json.dumps({"port": 9000, "tts": {"kokoro": {"voice": "bf_emma"}}}))
    cfg = config.load()
    assert cfg["port"] == 9000
    assert cfg["tts"]["kokoro"]["voice"] == "bf_emma"
    assert cfg["tts"]["engine"] == "kokoro"  # filled from defaults
    assert cfg["repos"] == {}


def test_token_is_generated_once(voclaude_home):
    from voclaude import config

    token = config.resolve_token(config.load())
    assert len(token) > 20
    assert config.resolve_token(config.load()) == token


def test_cli_watch_and_list(voclaude_home, tmp_path, monkeypatch, capsys):
    from voclaude import cli

    repo = tmp_path / "svc"
    repo.mkdir()
    monkeypatch.chdir(repo)
    assert cli.main(["watch", "--alias", "Backend"]) == 0
    assert "as 'backend'" in capsys.readouterr().out
    assert cli.main(["list"]) == 0
    assert str(repo.resolve()) in capsys.readouterr().out
