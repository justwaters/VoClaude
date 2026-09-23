#!/usr/bin/env python3
"""Verify local sesame/csm-1b speech generation.

Usage:
    python test_csm.py                          # uses tts settings from config.json
    python test_csm.py --text "Hello there." --out hello.wav

Requires access to the gated sesame/csm-1b repo: accept the terms at
https://huggingface.co/sesame/csm-1b, then run `hf auth login`.
"""

from __future__ import annotations

import argparse
import json
import logging
import time
from pathlib import Path

import numpy as np
import soundfile as sf

from csm_engine import SAMPLE_RATE, CSMEngine, SentenceChunker

BASE_DIR = Path(__file__).resolve().parent
DEFAULT_TEXT = (
    "Hey, I just finished running the test suite. "
    "Everything passed except one flaky network test, which I've retried and it's green now."
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", type=Path, default=BASE_DIR / "config.json")
    parser.add_argument("--text", default=DEFAULT_TEXT)
    parser.add_argument("--out", type=Path, default=BASE_DIR / "test_csm_output.wav")
    parser.add_argument("--device", help="override tts.device (cuda, mps, cpu)")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

    cfg = json.loads(args.config.read_text()).get("tts", {}).get("csm", {})
    if args.device:
        cfg["device"] = args.device
    engine = CSMEngine(cfg, BASE_DIR)

    t0 = time.perf_counter()
    engine.load()
    print(f"Model loaded in {time.perf_counter() - t0:.1f}s")

    # Split the text the same way the daemon does, so this also exercises voice consistency.
    chunker = SentenceChunker()
    sentences = chunker.feed(args.text) + chunker.flush()
    pieces = []
    for sentence in sentences:
        t0 = time.perf_counter()
        wav = engine.synthesize(sentence)
        elapsed = time.perf_counter() - t0
        seconds = wav.size / SAMPLE_RATE
        print(f"  {seconds:5.2f}s audio in {elapsed:5.2f}s (RTF {elapsed / max(seconds, 1e-6):.2f}): {sentence!r}")
        pieces.append(wav)
        pieces.append(np.zeros(int(0.15 * SAMPLE_RATE), dtype=np.float32))

    audio = np.concatenate(pieces)
    peak = float(np.abs(audio).max())
    assert audio.size > SAMPLE_RATE // 2, "generated audio is suspiciously short"
    assert peak > 0.01, "generated audio is silent"
    sf.write(str(args.out), audio, SAMPLE_RATE)
    print(f"OK — wrote {audio.size / SAMPLE_RATE:.1f}s to {args.out} (peak {peak:.2f})")


if __name__ == "__main__":
    main()
