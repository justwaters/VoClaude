#!/usr/bin/env python3
"""Stands in for the `claude` CLI: reads the prompt on stdin, emits stream-json like `claude -p`."""
import json
import sys
import uuid

args = sys.argv[1:]
session = args[args.index("--resume") + 1] if "--resume" in args else str(uuid.uuid4())
prompt = sys.stdin.read()


def emit(obj):
    print(json.dumps(obj), flush=True)


emit({"type": "system", "subtype": "init", "session_id": session})
emit({"type": "assistant", "message": {"content": [
    {"type": "tool_use", "name": "Bash", "input": {"command": "ls -la"}}]}})
for piece in ["You said: ", prompt.strip(), ". Done."]:
    emit({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": piece}}})
emit({"type": "stream_event", "event": {"type": "content_block_stop"}})
emit({"type": "result", "subtype": "success", "is_error": False, "result": "ok",
      "session_id": session, "total_cost_usd": 0.01})
