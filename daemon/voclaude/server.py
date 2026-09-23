"""voclaude-daemon: FastAPI WebSocket server bridging voice clients to headless Claude Code.

Protocol (JSON text frames on /ws/session/{repo_alias}):

  client → daemon
    {"type": "text",  "content": "...", "voice": "bf_emma"}     prompt as text
    {"type": "audio", "data": "<base64 pcm_s16le mono>", "sample_rate": 16000, "voice": "..."}
                                                                `voice` is optional; one of session.voices
    {"type": "cancel"}                                          stop the current turn
    {"type": "reset"}                                           start a fresh Claude session
    {"type": "ping"}

  daemon → client
    {"type": "session", "repo", "display_name", "session_id", "tts", "stt",
     "voices": [{"id": "af_heart", "name": "Heart (American, female)"}, ...], "default_voice"}
    {"type": "status", "state": "transcribing|thinking|speaking|done"}
    {"type": "user_transcript", "content": "..."}               STT result for uploaded audio
    {"type": "text", "content": "..."}                          assistant text delta
    {"type": "tool", "name": "Bash", "summary": "npm test"}
    {"type": "audio", "data": "<base64 pcm_s16le mono>", "sample_rate": 24000}
    {"type": "result", "is_error": false, "session_id": "...", "cost_usd": 0.01}
    {"type": "error", "message": "..."}
    {"type": "pong"}

Auth: every request must carry the daemon token, either as
`Authorization: Bearer <token>` or a `?token=<token>` query parameter.
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import secrets
from contextlib import aclosing, asynccontextmanager

import uvicorn
from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect

from . import __version__, config
from .csm_engine import CSMEngine, SentenceChunker, to_pcm16
from .discovery import Advertiser
from .kokoro_engine import KokoroEngine
from .session_manager import (
    SessionBusyError,
    SessionManager,
    StateStore,
    TextBlockEnd,
    TextDelta,
    ToolUse,
    TurnResult,
)
from .stt_engine import STTEngine

log = logging.getLogger("voclaude")

TTSEngine = CSMEngine | KokoroEngine
AUDIO_CHUNK_SECONDS = 1.0


class Daemon:
    def __init__(self, cfg: dict):
        self.config = cfg
        self.state = StateStore(config.STATE_PATH)
        self.token = config.resolve_token(cfg)
        self.sessions = SessionManager(cfg.get("repos", {}), cfg.get("claude", {}), self.state)
        self._config_mtime = self._mtime()

        tts_cfg = self.config.get("tts", {})
        stt_cfg = self.config.get("stt", {})
        self.tts = self._make_tts(tts_cfg) if tts_cfg.get("enabled", True) else None
        self.stt = STTEngine(stt_cfg) if stt_cfg.get("enabled", True) else None
        self._preload = [e for e, cfg in ((self.tts, tts_cfg), (self.stt, stt_cfg)) if e and cfg.get("preload")]

    @staticmethod
    def _make_tts(cfg: dict) -> TTSEngine:
        engine = cfg.get("engine", "kokoro")
        if engine == "kokoro":
            return KokoroEngine(cfg.get("kokoro", {}))
        if engine == "csm":
            return CSMEngine(cfg.get("csm", {}), config.CONFIG_DIR)
        raise ValueError(f"Unknown tts.engine {engine!r}; expected 'kokoro' or 'csm'")

    @staticmethod
    def _mtime() -> float:
        try:
            return config.CONFIG_PATH.stat().st_mtime
        except FileNotFoundError:
            return 0.0

    def refresh_repos(self) -> None:
        """Pick up repos added or removed with `voclaude watch` / `unwatch` since startup."""
        mtime = self._mtime()
        if mtime == self._config_mtime:
            return
        self._config_mtime = mtime
        try:
            repos = config.load().get("repos", {})
        except (OSError, json.JSONDecodeError) as exc:
            log.warning("Couldn't reload %s: %s", config.CONFIG_PATH, exc)
            return
        self.sessions.sync(repos)

    def authorized(self, headers, query_params) -> bool:
        supplied = query_params.get("token") or ""
        auth = headers.get("authorization", "")
        if auth.lower().startswith("bearer "):
            supplied = auth[7:].strip()
        return secrets.compare_digest(supplied.encode(), self.token.encode())

    async def preload(self) -> None:
        for engine in self._preload:
            try:
                await asyncio.to_thread(engine.load)
            except Exception:
                log.exception("Preloading %s failed", type(engine).__name__)


def create_app(daemon: Daemon) -> FastAPI:
    @asynccontextmanager
    async def lifespan(_: FastAPI):
        preload = asyncio.create_task(daemon.preload())
        advertiser = Advertiser(daemon.config.get("port", 8000))
        if daemon.config.get("discovery", True):
            try:
                await advertiser.start()
            except Exception:
                log.exception("Bonjour advertising failed; the app can still connect by address")
        yield
        preload.cancel()
        await advertiser.stop()

    app = FastAPI(title="voclaude-daemon", lifespan=lifespan)

    @app.get("/health")
    async def health():
        return {
            "ok": True,
            "version": __version__,
            "tts_loaded": bool(daemon.tts and daemon.tts.loaded),
            "tts_error": str(daemon.tts.load_error) if daemon.tts and daemon.tts.load_error else None,
        }

    @app.get("/sessions")
    async def list_sessions(request: Request):
        if not daemon.authorized(request.headers, request.query_params):
            raise HTTPException(status_code=401, detail="invalid token")
        daemon.refresh_repos()
        return [
            {
                "alias": repo.alias,
                "display_name": repo.display_name,
                "session_id": repo.session_id,
                "busy": daemon.sessions.is_busy(repo.alias),
            }
            for repo in daemon.sessions.repos.values()
        ]

    @app.websocket("/ws/session/{repo_alias}")
    async def ws_session(ws: WebSocket, repo_alias: str):
        if not daemon.authorized(ws.headers, ws.query_params):
            await ws.close(code=1008, reason="invalid token")
            return
        daemon.refresh_repos()
        if repo_alias not in daemon.sessions.repos:
            await ws.close(code=4404, reason=f"unknown repo '{repo_alias}'")
            return
        await ws.accept()
        await Connection(daemon, ws, repo_alias).serve()

    return app


class Outbound:
    """Serializes sends from the turn task, the TTS worker and the receive loop."""

    def __init__(self, ws: WebSocket):
        self._ws = ws
        self._lock = asyncio.Lock()

    async def send(self, payload: dict) -> None:
        async with self._lock:
            await self._ws.send_json(payload)

    async def status(self, state: str) -> None:
        await self.send({"type": "status", "state": state})

    async def error(self, message: str) -> None:
        await self.send({"type": "error", "message": message})


class SpeechPipeline:
    """Synthesizes sentences in order on a background task while Claude keeps streaming."""

    def __init__(self, out: Outbound, tts: TTSEngine, voice: str | None):
        self._out = out
        self._tts = tts
        self._voice = voice
        self._queue: asyncio.Queue[str | None] = asyncio.Queue()
        self._task = asyncio.create_task(self._worker())

    def say(self, sentences: list[str]) -> None:
        for sentence in sentences:
            self._queue.put_nowait(sentence)

    async def finish(self) -> None:
        self._queue.put_nowait(None)
        await self._task

    def cancel(self) -> None:
        self._task.cancel()

    async def _worker(self) -> None:
        speaking = False
        while (text := await self._queue.get()) is not None:
            try:
                wav = await asyncio.to_thread(self._tts.synthesize, text, self._voice)
            except Exception as exc:
                log.exception("TTS failed")
                await self._out.error(f"Speech synthesis failed: {exc}")
                return  # keep streaming text; stop trying to speak this turn
            if not speaking:
                speaking = True
                await self._out.status("speaking")
            rate = self._tts.sample_rate
            pcm = to_pcm16(wav)
            step = int(rate * AUDIO_CHUNK_SECONDS) * 2
            for i in range(0, len(pcm), step):
                await self._out.send({
                    "type": "audio",
                    "data": base64.b64encode(pcm[i:i + step]).decode(),
                    "sample_rate": rate,
                    "format": "pcm_s16le",
                })


class Connection:
    def __init__(self, daemon: Daemon, ws: WebSocket, alias: str):
        self.daemon = daemon
        self.ws = ws
        self.alias = alias
        self.out = Outbound(ws)
        self.turn: asyncio.Task | None = None

    async def serve(self) -> None:
        await self._send_session()
        try:
            while True:
                raw = await self.ws.receive_text()
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    await self.out.error("Malformed JSON")
                    continue
                await self._dispatch(msg)
        except WebSocketDisconnect:
            pass
        finally:
            if self.turn and not self.turn.done():
                self.turn.cancel()

    async def _dispatch(self, msg: dict) -> None:
        kind = msg.get("type")
        busy = self.turn is not None and not self.turn.done()

        if kind in ("text", "audio"):
            if busy or self.daemon.sessions.is_busy(self.alias):
                await self.out.error("A turn is already running for this repo. Send cancel first.")
                return
            self.turn = asyncio.create_task(self._run_turn(msg))
        elif kind == "cancel":
            if busy:
                self.turn.cancel()
        elif kind == "reset":
            try:
                self.daemon.sessions.reset(self.alias)
            except SessionBusyError as exc:
                await self.out.error(str(exc))
                return
            await self._send_session()
        elif kind == "ping":
            await self.out.send({"type": "pong"})
        else:
            await self.out.error(f"Unknown message type: {kind!r}")

    async def _send_session(self) -> None:
        repo = self.daemon.sessions.get(self.alias)
        tts = self.daemon.tts
        await self.out.send({
            "type": "session",
            "repo": repo.alias,
            "display_name": repo.display_name,
            "session_id": repo.session_id,
            "tts": self.daemon.tts is not None,
            "stt": self.daemon.stt is not None,
            "voices": tts.voice_options() if tts else [],
            "default_voice": tts.default_voice if tts else None,
        })
        if self.daemon.tts and self.daemon.tts.load_error:
            await self.out.error(f"Speech is unavailable: {self.daemon.tts.load_error}")

    async def _prompt_from(self, msg: dict) -> str:
        if msg["type"] == "text":
            return str(msg.get("content", "")).strip()

        if self.daemon.stt is None:
            raise ValueError("Server-side transcription is disabled; send text instead.")
        try:
            pcm = base64.b64decode(msg.get("data", ""), validate=True)
        except ValueError:
            raise ValueError("Audio payload is not valid base64") from None
        await self.out.status("transcribing")
        prompt = await asyncio.to_thread(self.daemon.stt.transcribe, pcm, int(msg.get("sample_rate", 16000)))
        await self.out.send({"type": "user_transcript", "content": prompt})
        return prompt

    async def _run_turn(self, msg: dict) -> None:
        speech: SpeechPipeline | None = None
        try:
            prompt = await self._prompt_from(msg)
            if not prompt:
                await self.out.error("Didn't catch that — no speech detected.")
                return

            await self.out.status("thinking")
            tts = self.daemon.tts
            # After a load failure (reported once on connect / first turn) just stream text.
            speech = None
            if tts and not tts.load_error:
                speech = SpeechPipeline(self.out, tts, tts.resolve_voice(msg.get("voice")))
            chunker = SentenceChunker()

            async with aclosing(self.daemon.sessions.run(self.alias, prompt)) as events:
                async for event in events:
                    if isinstance(event, TextDelta):
                        await self.out.send({"type": "text", "content": event.text})
                        if speech:
                            speech.say(chunker.feed(event.text))
                    elif isinstance(event, TextBlockEnd):
                        if speech:
                            speech.say(chunker.flush())
                    elif isinstance(event, ToolUse):
                        await self.out.send({"type": "tool", "name": event.name, "summary": event.summary})
                    elif isinstance(event, TurnResult):
                        await self.out.send({
                            "type": "result",
                            "is_error": event.is_error,
                            "session_id": event.session_id,
                            "cost_usd": event.cost_usd,
                        })
                        if event.is_error:
                            await self.out.error(event.text or "Claude reported an error")

            if speech:
                speech.say(chunker.flush())
                await speech.finish()
        except asyncio.CancelledError:
            if speech:
                speech.cancel()
            raise
        except (ValueError, SessionBusyError) as exc:
            await self.out.error(str(exc))
        except Exception as exc:
            log.exception("Turn failed")
            await self.out.error(f"Turn failed: {exc}")
        finally:
            try:
                await self.out.status("done")
            except Exception:
                pass  # socket already gone


def run(host: str | None = None, port: int | None = None, log_level: str = "info") -> None:
    """Start the daemon with the user config (see `voclaude serve`)."""
    logging.basicConfig(level=log_level.upper(), format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    cfg = config.load()
    if port:
        cfg["port"] = port
    host = host or cfg.get("host", "0.0.0.0")
    daemon = Daemon(cfg)

    repos = daemon.sessions.repos.values()
    log.info("VoClaude %s — config %s", __version__, config.CONFIG_PATH)
    if repos:
        log.info("Watching: %s", ", ".join(f"{r.alias} → {r.path}" for r in repos))
    else:
        log.warning("No repos watched yet. Run `voclaude watch` inside a repo to add it.")
    log.info("Auth token: %s", daemon.token)

    uvicorn.run(create_app(daemon), host=host, port=cfg["port"], log_level=log_level, ws_max_size=32 * 1024 * 1024)
