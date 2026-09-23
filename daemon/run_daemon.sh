#!/usr/bin/env bash
# Start voclaude-daemon, creating the virtualenv and installing dependencies on first run.
#   ./run_daemon.sh                   # host/port from config.json
#   ./run_daemon.sh --port 9000
#   PYTHON=python3.11 ./run_daemon.sh
set -euo pipefail
cd "$(dirname "$0")"

VENV=.venv
PYTHON="${PYTHON:-python3.12}"
command -v "$PYTHON" >/dev/null 2>&1 || PYTHON=python3

if ! command -v claude >/dev/null 2>&1; then
  echo "error: 'claude' CLI not found on PATH (install Claude Code and run 'claude' once to log in)" >&2
  exit 1
fi

if [ ! -x "$VENV/bin/python" ]; then
  echo "Creating virtualenv with $PYTHON…"
  if command -v uv >/dev/null 2>&1; then
    uv venv --python "$PYTHON" "$VENV"
  else
    "$PYTHON" -m venv "$VENV"
  fi
fi

if [ ! -f "$VENV/.installed" ] || [ requirements.txt -nt "$VENV/.installed" ]; then
  echo "Installing dependencies…"
  if command -v uv >/dev/null 2>&1; then
    uv pip install --python "$VENV/bin/python" -r requirements.txt
  else
    "$VENV/bin/pip" install --upgrade pip
    "$VENV/bin/pip" install -r requirements.txt
  fi
  touch "$VENV/.installed"
fi

exec "$VENV/bin/python" main.py "$@"
