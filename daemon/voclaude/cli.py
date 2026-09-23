"""The `voclaude` command.

    voclaude watch [--alias NAME]   watch the repo you're in
    voclaude unwatch [ALIAS]        stop watching it (or the named alias)
    voclaude list                   show watched repos
    voclaude serve                  start the daemon (installs speech deps on first run)
    voclaude token                  print the token the app needs
    voclaude say "text"             speak a test sentence to a WAV file
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

from . import __version__, config


def cmd_watch(args: argparse.Namespace) -> int:
    try:
        alias, added = config.watch(Path.cwd(), alias=args.alias, display_name=args.name)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    repo = config.load()["repos"][alias]
    if added:
        print(f"Watching {repo['path']} as '{alias}'.")
        print("A running `voclaude serve` picks it up automatically; it shows up in the app when you refresh.")
    else:
        print(f"Already watching {repo['path']} as '{alias}'.")
    return 0


def cmd_unwatch(args: argparse.Namespace) -> int:
    alias = config.unwatch(args.target or Path.cwd())
    if alias is None:
        print(f"Not watching {args.target or Path.cwd()}.", file=sys.stderr)
        return 1
    print(f"Stopped watching '{alias}'.")
    return 0


def cmd_list(_: argparse.Namespace) -> int:
    repos = config.load()["repos"]
    if not repos:
        print("No repos watched. Run `voclaude watch` inside a repo.")
        return 0
    width = max(len(alias) for alias in repos)
    for alias, repo in repos.items():
        missing = "" if Path(repo["path"]).expanduser().is_dir() else "  (missing)"
        print(f"{alias:<{width}}  {repo['path']}{missing}")
    return 0


def cmd_token(_: argparse.Namespace) -> int:
    print(config.resolve_token(config.load()))
    return 0


def cmd_serve(args: argparse.Namespace) -> int:
    cfg = config.load()
    claude_bin = cfg["claude"]["bin"]
    if shutil.which(claude_bin) is None:
        print(f"error: '{claude_bin}' isn't on PATH. Install Claude Code and run `claude` once to log in.",
              file=sys.stderr)
        return 1

    from . import deps

    try:
        deps.ensure(cfg)
    except Exception as exc:  # subprocess failures, no network, …
        print(f"error: couldn't install speech dependencies: {exc}", file=sys.stderr)
        return 1

    from .server import run

    run(host=args.host, port=args.port, log_level=args.log_level)
    return 0


def cmd_say(args: argparse.Namespace) -> int:
    import time

    cfg = config.load()
    if args.engine:
        cfg["tts"]["engine"] = args.engine
    from . import deps

    deps.ensure({**cfg, "stt": {"enabled": False}})

    import numpy as np
    import soundfile as sf

    from .csm_engine import SentenceChunker
    from .server import Daemon

    engine = Daemon._make_tts(cfg["tts"])
    started = time.perf_counter()
    engine.load()
    print(f"Loaded {cfg['tts']['engine']} in {time.perf_counter() - started:.1f}s")

    chunker = SentenceChunker()
    sentences = chunker.feed(args.text) + chunker.flush()
    voice = engine.resolve_voice(args.voice)
    started = time.perf_counter()
    audio = np.concatenate([engine.synthesize(s, voice) for s in sentences])
    spent = time.perf_counter() - started
    seconds = audio.size / engine.sample_rate
    if seconds < 0.3 or float(np.abs(audio).max()) < 0.01:
        print("error: generated audio is empty or silent", file=sys.stderr)
        return 1
    sf.write(args.out, audio, engine.sample_rate)
    print(f"{seconds:.1f}s of audio in {spent:.1f}s (RTF {spent / seconds:.2f}), voice {voice or 'default'} → {args.out}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="voclaude", description="Talk to headless Claude Code from the VoClaude app.")
    parser.add_argument("--version", action="version", version=f"voclaude {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("watch", help="watch the repo in the current directory")
    p.add_argument("--alias", help="name used in the app's URL (default: the folder name)")
    p.add_argument("--name", help="display name shown in the app (default: the folder name)")
    p.set_defaults(func=cmd_watch)

    p = sub.add_parser("unwatch", help="stop watching a repo")
    p.add_argument("target", nargs="?", help="alias or path (default: the current repo)")
    p.set_defaults(func=cmd_unwatch)

    p = sub.add_parser("list", help="list watched repos")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("serve", help="start the daemon, installing speech dependencies if needed")
    p.add_argument("--host", help="interface to bind (default from config: 0.0.0.0)")
    p.add_argument("--port", type=int, help="port (default from config: 8000)")
    p.add_argument("--log-level", default="info")
    p.set_defaults(func=cmd_serve)

    p = sub.add_parser("token", help="print the auth token for the app")
    p.set_defaults(func=cmd_token)

    p = sub.add_parser("say", help="speak text to a WAV file to test speech")
    p.add_argument("text", nargs="?",
                   default="Hey, I just finished running the test suite. Everything passed.")
    p.add_argument("--voice", help="voice ID, e.g. bf_emma")
    p.add_argument("--engine", choices=["kokoro", "csm"])
    p.add_argument("--out", default="voclaude-say.wav")
    p.set_defaults(func=cmd_say)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
