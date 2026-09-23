"""Runs headless Claude Code CLI turns and maps repo aliases to persistent sessions."""

from __future__ import annotations

import asyncio
import json
import logging
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, AsyncIterator, Union

log = logging.getLogger("voclaude.sessions")

# stream-json lines carrying tool results can be large; the asyncio default is 64 KiB.
STREAM_LIMIT = 32 * 1024 * 1024


# --- Events yielded to the WebSocket layer ---------------------------------


@dataclass
class TextDelta:
    text: str


@dataclass
class TextBlockEnd:
    """A content block finished; buffered speech should be flushed."""


@dataclass
class ToolUse:
    name: str
    summary: str


@dataclass
class TurnResult:
    session_id: str | None
    is_error: bool
    text: str
    cost_usd: float | None = None


ClaudeEvent = Union[TextDelta, TextBlockEnd, ToolUse, TurnResult]


class UnknownRepoError(KeyError):
    pass


class SessionBusyError(RuntimeError):
    pass


class _StaleSessionError(RuntimeError):
    pass


# --- Persistent state (discovered session IDs, generated auth token) --------


class StateStore:
    """Small JSON file for values the daemon learns at runtime.

    Kept separate from config.json so the daemon never rewrites user-edited config.
    """

    def __init__(self, path: Path):
        self.path = path
        self._lock = threading.Lock()
        try:
            self._data: dict[str, Any] = json.loads(path.read_text())
        except FileNotFoundError:
            self._data = {}
        except json.JSONDecodeError:
            log.warning("State file %s is corrupt; starting fresh", path)
            self._data = {}

    def get(self, key: str, default: Any = None) -> Any:
        with self._lock:
            return self._data.get(key, default)

    def set(self, key: str, value: Any) -> None:
        with self._lock:
            self._data[key] = value
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(self._data, indent=2))
            tmp.replace(self.path)


# --- Session manager ---------------------------------------------------------


@dataclass
class Repo:
    alias: str
    path: Path
    display_name: str
    session_id: str | None
    extra_args: list[str] = field(default_factory=list)


class SessionManager:
    def __init__(self, repos_cfg: dict, claude_cfg: dict, state: StateStore):
        self._state = state
        self._bin = claude_cfg.get("bin", "claude")
        self._allowed_tools: list[str] = claude_cfg.get("allowed_tools", ["Read", "Edit", "Bash"])
        self._permission_mode: str | None = claude_cfg.get("permission_mode")
        self._extra_args: list[str] = claude_cfg.get("extra_args", [])

        saved = state.get("sessions", {})
        self.repos: dict[str, Repo] = {}
        for alias, rc in repos_cfg.items():
            path = Path(rc["path"]).expanduser().resolve()
            if not path.is_dir():
                log.warning("Repo %s path does not exist: %s", alias, path)
            # An explicit session_id in config.json wins over one discovered at runtime.
            self.repos[alias] = Repo(
                alias=alias,
                path=path,
                display_name=rc.get("display_name", alias),
                session_id=rc.get("session_id") or saved.get(alias),
                extra_args=rc.get("extra_args", []),
            )
        self._locks = {alias: asyncio.Lock() for alias in self.repos}

    def get(self, alias: str) -> Repo:
        try:
            return self.repos[alias]
        except KeyError:
            raise UnknownRepoError(alias) from None

    def is_busy(self, alias: str) -> bool:
        return self._locks[self.get(alias).alias].locked()

    def reset(self, alias: str) -> None:
        """Forget the session so the next prompt starts a fresh conversation."""
        repo = self.get(alias)
        if self.is_busy(alias):
            raise SessionBusyError(f"{alias} is running a turn")
        repo.session_id = None
        self._persist(repo)

    async def run(self, alias: str, prompt: str) -> AsyncIterator[ClaudeEvent]:
        """Run one Claude turn in the repo, yielding events as they stream in.

        Cancelling the consuming task terminates the claude subprocess.
        """
        repo = self.get(alias)
        lock = self._locks[alias]
        if lock.locked():
            raise SessionBusyError(f"{alias} is already running a turn")
        async with lock:
            try:
                async for event in self._run_once(repo, prompt, resume=repo.session_id is not None):
                    yield event
            except _StaleSessionError:
                log.warning("Session %s for %s no longer exists; starting fresh", repo.session_id, alias)
                repo.session_id = None
                self._persist(repo)
                async for event in self._run_once(repo, prompt, resume=False):
                    yield event

    def _command(self, repo: Repo, resume: bool) -> list[str]:
        cmd = [
            self._bin,
            "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
        ]
        if self._allowed_tools:
            cmd += ["--allowedTools", ",".join(self._allowed_tools)]
        if self._permission_mode:
            cmd += ["--permission-mode", self._permission_mode]
        if resume and repo.session_id:
            cmd += ["--resume", repo.session_id]
        return cmd + self._extra_args + repo.extra_args

    async def _run_once(self, repo: Repo, prompt: str, resume: bool) -> AsyncIterator[ClaudeEvent]:
        cmd = self._command(repo, resume)
        log.info("[%s] %s", repo.alias, " ".join(cmd))
        # The prompt goes over stdin so user text can never be parsed as a CLI flag.
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            cwd=repo.path,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            limit=STREAM_LIMIT,
        )
        assert proc.stdin and proc.stdout and proc.stderr
        stderr_task = asyncio.create_task(proc.stderr.read())
        yielded = False
        got_result = False
        try:
            proc.stdin.write(prompt.encode())
            await proc.stdin.drain()
            proc.stdin.close()

            async for raw in proc.stdout:
                line = raw.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    log.debug("[%s] non-JSON output: %r", repo.alias, line[:200])
                    continue

                if msg.get("type") == "system" and msg.get("subtype") == "init":
                    self._remember(repo, msg.get("session_id"))
                    continue

                for event in _translate(msg):
                    if isinstance(event, TurnResult):
                        got_result = True
                        self._remember(repo, event.session_id)
                    yielded = True
                    yield event

            rc = await proc.wait()
            stderr = (await stderr_task).decode(errors="replace").strip()
            if not got_result:
                if resume and not yielded and "No conversation found" in stderr:
                    raise _StaleSessionError(stderr)
                yield TurnResult(
                    session_id=repo.session_id,
                    is_error=True,
                    text=stderr[-800:] or f"claude exited with status {rc}",
                )
        finally:
            if proc.returncode is None:
                proc.terminate()
                try:
                    await asyncio.wait_for(proc.wait(), timeout=5)
                except asyncio.TimeoutError:
                    proc.kill()
            if not stderr_task.done():
                stderr_task.cancel()

    def _remember(self, repo: Repo, session_id: str | None) -> None:
        if session_id and session_id != repo.session_id:
            repo.session_id = session_id
            self._persist(repo)

    def _persist(self, repo: Repo) -> None:
        sessions = dict(self._state.get("sessions", {}))
        if repo.session_id:
            sessions[repo.alias] = repo.session_id
        else:
            sessions.pop(repo.alias, None)
        self._state.set("sessions", sessions)


# --- stream-json translation ---------------------------------------------------


def _translate(msg: dict) -> list[ClaudeEvent]:
    kind = msg.get("type")

    if kind == "stream_event":
        event = msg.get("event", {})
        if event.get("type") == "content_block_delta":
            delta = event.get("delta", {})
            if delta.get("type") == "text_delta" and delta.get("text"):
                return [TextDelta(delta["text"])]
        elif event.get("type") == "content_block_stop":
            return [TextBlockEnd()]
        return []

    if kind == "assistant":
        # Text already arrived via stream_event deltas; only surface tool calls here.
        content = msg.get("message", {}).get("content", [])
        return [
            ToolUse(name=block.get("name", "tool"), summary=_summarize_tool_input(block.get("input", {})))
            for block in content
            if block.get("type") == "tool_use"
        ]

    if kind == "result":
        return [
            TurnResult(
                session_id=msg.get("session_id"),
                is_error=bool(msg.get("is_error")) or msg.get("subtype") != "success",
                text=msg.get("result") or "",
                cost_usd=msg.get("total_cost_usd"),
            )
        ]

    return []


def _summarize_tool_input(tool_input: dict) -> str:
    for key in ("command", "file_path", "path", "pattern", "url", "description"):
        if isinstance(tool_input.get(key), str):
            return _truncate(tool_input[key])
    return _truncate(json.dumps(tool_input)) if tool_input else ""


def _truncate(text: str, limit: int = 160) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1] + "…"
