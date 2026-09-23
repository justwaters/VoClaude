# VoClaude

Talk to Claude Code on your computer from your iPhone, or call it like a phone.

```
iPhone / Mac app ──Bonjour discovery──▶ voclaude serve ──stdin/stream-json──▶ claude -p   (in each watched repo)
   mic (push-to-talk or hands-free call) ─ pcm16 16 kHz ─▶ faster-whisper
   speaker                              ◀─ pcm16 24 kHz ── Kokoro-82M (default) or sesame/csm-1b
```

## Install the daemon (macOS or Linux)

You need [uv](https://docs.astral.sh/uv/) and the [Claude Code](https://docs.claude.com/en/docs/claude-code) CLI,
logged in (run `claude` once).

```bash
uv tool install "git+https://github.com/justwaters/VoClaude@v0.1.0"
```

uv picks a compatible Python (3.10–3.12) on its own.

## Use it

```bash
cd ~/code/my-app
voclaude watch          # add this repo; run it in each repo you want to talk to
voclaude serve          # start the daemon
```

- **First `serve`:** it installs the speech engine (PyTorch, Kokoro, faster-whisper; a few GB) and
  downloads the voices. Later starts take about 10 seconds.
- **The token:** `serve` prints an **auth token**, and `voclaude token` prints it again at any time.
  The daemon lets Claude run `Bash` in your repos, so every connection needs it.
- **Discovery:** the daemon announces itself on your network over Bonjour, so the app finds it without
  an IP address.
- **No restart needed:** repos you `watch` while `serve` is running show up right away.

Other commands:

| Command | What it does |
|---|---|
| `voclaude list` | Show watched repos |
| `voclaude unwatch [alias]` | Stop watching the current repo (or the named one) |
| `voclaude token` | Print the token the app needs |
| `voclaude say "Hello" --voice bf_emma` | Speak a test sentence to `voclaude-say.wav` |
| `voclaude serve --port 9000` | Use another port (default 8000) |

Settings live in `~/.config/voclaude/config.json`; set `VOCLAUDE_HOME` to move them. To upgrade, run
`uv tool upgrade voclaude`; the next `serve` reinstalls the speech engine if the upgrade removed it.

## Install the app (iPhone or Mac)

1. Open `client/VoClaude.xcodeproj` in Xcode, select the **VoClaude** target, and pick your **Team**
   under **Signing & Capabilities**.
2. Pick a device and press ⌘R.
   - **iPhone:** turn on Developer Mode (Settings → Privacy & Security) and trust your developer
     profile when asked.
   - **Free Apple ID:** the iPhone build expires after 7 days.
3. On first launch, allow **Local Network** access. Your computer then appears under **Nearby**.
4. Tap your computer, paste the token, and choose the repos to add.

The project is generated from `client/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen).
After editing that file, run `cd client && xcodegen generate`.

### Talking to Claude

- **Hold the mic button** to talk, then release to send. Claude's reply appears as text and is read aloud.
- **Tap the green phone button** to start a hands-free call. On iPhone it's a real call: it shows in the
  Dynamic Island and on the lock screen, keeps going with the screen off or in another app, uses the
  earpiece or your AirPods, and appears in Recents.
  - **Taking turns:** talk normally and pause when you're done. VoClaude sends what you said, waits for
    Claude, reads the answer, then listens again.
  - **In-call controls:** mute, speaker, **Stop** (cancel Claude's current turn), and end call.
- **Session → Voice** picks the voice for each repo: Heart, Emma, Puck, or George.
- **Stop** cancels a running turn.
- **Switching repos** doesn't interrupt work in the other one; only the selected repo speaks.

You can also add a daemon by hand with **+**: enter a host like `192.168.1.5:8000` or a Tailscale IP.

## Speech engines

`tts.engine` in the config picks the engine:

- **`kokoro`** (default): Kokoro-82M runs on a plain CPU, about 7× faster than real time on an M2 Pro.
  - **Voices:** `af_heart` (American female, the default), `bf_emma` (British female), `am_puck`
    (American male) and `bm_george` (British male).
  - **More voices:** add any other [Kokoro voice](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md)
    to `tts.kokoro.voices`.
- **`csm`**: Sesame's `sesame/csm-1b` needs a CUDA GPU; on Apple Silicon it's 4–10× slower than real time.
  - **Access:** the model is gated. Request access on Hugging Face, then run `hf auth login`.
  - **Voice:** the open weights don't include Sesame's Maya voice. Set `tts.csm.voice_prompt` to a short
    WAV clip and its exact transcript for a specific voice.

Only Claude's prose is read aloud; code blocks are skipped.

## Notes

- **Sessions.** Each repo keeps one Claude conversation, resumed across turns and restarts.
  **Session → New Claude Conversation** in the app starts a fresh one.
- **Permissions.** Claude runs with `--allowedTools Read,Edit,Bash`. Change this with `claude.allowed_tools`,
  `claude.permission_mode` and `claude.extra_args` in the config.
- **Network.** The app connects over plain `ws://` on your LAN or Tailscale. Put the daemon behind TLS
  before exposing it anywhere else.
- **Protocol.** The WebSocket protocol is documented at the top of `daemon/voclaude/server.py`.

## Development

```bash
uv run --group dev pytest            # daemon tests (uses a fake claude CLI)
cd client && xcodebuild test -scheme VoClaude -destination 'platform=macOS'   # app tests
```
