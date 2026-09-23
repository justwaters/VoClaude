#!/usr/bin/env python3
"""Verify the configured Kokoro voices generate audio and report their speed.

Usage:
    python test_tts.py                    # every voice in tts.kokoro.voices
    python test_tts.py --voice bf_emma    # just one

Writes test_tts_<voice>.wav next to this script.
"""

from __future__ import annotations

import argparse
import json
import logging
import time
import warnings
from pathlib import Path

import numpy as np
import soundfile as sf

from csm_engine import SentenceChunker
from kokoro_engine import KokoroEngine

BASE_DIR = Path(__file__).resolve().parent
TEXT = (
    "Hey, I just finished running the test suite. "
    "Everything passed except one flaky network test, which I've retried and it's green now."
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", type=Path, default=BASE_DIR / "config.json")
    parser.add_argument("--voice", action="append", help="voice ID to test (repeatable)")
    parser.add_argument("--text", default=TEXT)
    args = parser.parse_args()
    warnings.filterwarnings("ignore")
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

    engine = KokoroEngine(json.loads(args.config.read_text()).get("tts", {}).get("kokoro", {}))
    t0 = time.perf_counter()
    engine.load()
    print(f"Kokoro loaded in {time.perf_counter() - t0:.1f}s")

    chunker = SentenceChunker()
    sentences = chunker.feed(args.text) + chunker.flush()
    for voice in args.voice or engine.voices:
        if voice not in engine.voices:
            raise SystemExit(f"{voice} is not in tts.kokoro.voices ({', '.join(engine.voices)})")
        audio, spent = [], 0.0
        for sentence in sentences:
            t0 = time.perf_counter()
            audio.append(engine.synthesize(sentence, voice))
            spent += time.perf_counter() - t0
        wav = np.concatenate(audio)
        seconds = wav.size / engine.sample_rate
        assert seconds > 0.5 and np.abs(wav).max() > 0.01, f"{voice}: audio is empty or silent"
        out = BASE_DIR / f"test_tts_{voice}.wav"
        sf.write(str(out), wav, engine.sample_rate)
        print(f"  {voice:10} {seconds:5.2f}s audio in {spent:5.2f}s (RTF {spent / seconds:.2f}) → {out.name}")
    print("OK")


if __name__ == "__main__":
    main()
