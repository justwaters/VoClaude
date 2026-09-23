# VoClaude

Talk to headless Claude Code sessions on a remote machine from an iOS or macOS app.

```
VoClaude app ──ws://host:8000/ws/session/<repo>──▶ voclaude-daemon ──stdin/stream-json──▶ claude -p
   push-to-talk mic  ─ pcm16 16 kHz ─▶  faster-whisper
   gapless player   ◀─ pcm16 24 kHz ──  Kokoro-82M (default) or sesame/csm-1b
```

## Daemon (`daemon/`)

Requirements: Python 3.11+ and the `claude` CLI logged in on the host.

1. Edit `daemon/config.json` so each repo alias points at its path.
2. Run `daemon/run_daemon.sh`. The first run creates `.venv` and installs the dependencies.
3. Copy the **auth token** from the startup log. The daemon runs `Bash` in your repos, so it always
   requires a token. If none is set in config.json or `VOCLAUDE_TOKEN`, one is generated and saved
   to `daemon/state.json`.

### Speech engines

`tts.engine` in config.json picks the engine:

- **`kokoro`** (default): Kokoro-82M runs on a plain CPU on macOS or Linux, about 7× faster than
  real time on an M2 Pro. The voices come from `tts.kokoro.voices`: `af_heart` (Heart, American female,
  the default), `bf_emma` (Emma, British female), `am_puck` (Puck, American male) and `bm_george`
  (George, British male). Pick one per session from the app's **Session → Voice** menu. You can list
  any other Kokoro voice ID in config.json too.
- **`csm`**: Sesame's `sesame/csm-1b` is richer but needs a CUDA GPU; on Apple Silicon it runs 4–10×
  slower than real time. The model is gated: request access, then run `hf auth login`. The open weights
  don't include Sesame's Maya voice. Set `tts.csm.voice_prompt` to a short WAV clip and its exact
  transcript for a specific voice.

To check speech on its own, run `.venv/bin/python test_tts.py` (Kokoro, every configured voice) or
`.venv/bin/python test_csm.py` from `daemon/`. Both write WAV files and print the real-time factor.

Notes:
- **Sessions.** Session IDs the daemon discovers are saved to `state.json`. A `session_id` set in
  config.json takes precedence. "New Claude Conversation" in the app clears the saved ID.
- **What's spoken.** Only Claude's prose is read aloud; code blocks are skipped.
- **Permissions.** Claude runs with `--allowedTools Read,Edit,Bash`. Use `claude.permission_mode` and
  `extra_args` in config.json to change that.

The WebSocket protocol is documented at the top of `daemon/main.py`.

## App (`client/`)

`client/project.yml` defines the Xcode project (XcodeGen). After changing it, run `cd client && xcodegen generate`.

1. Open `client/VoClaude.xcodeproj`, set your development team, and run on iOS 17+ or macOS 14+.
2. Add a session with the daemon host (`192.168.1.100:8000`), the repo alias (`repo_a`) and the token.
   The token is stored in the Keychain.
3. Hold the mic button to talk and release to send. **Stop** cancels the running turn.

Each session keeps its own WebSocket open, so switching repos doesn't interrupt work in the other one.
Only the selected session plays audio. **Settings → Transcribe on device** uses Apple Speech
instead of uploading audio to faster-whisper.

The app uses plain `ws://` (ATS arbitrary loads are enabled) because it's meant for a LAN or Tailscale.
Put the daemon behind TLS before exposing it anywhere else.
