#!/usr/bin/env python3
"""Transcribe WAV/reference pairs with the Python rig's recognizer (parakeet-mlx).

Writes the same JSONL as the apps' `tcasr`, so
`scripts/check-polyglot-recognition.py score` scores both alike:

    uv run python scripts/mlx-recognition.py v3 runs/recognition-2026-10-16/audio runs/X/mlx-v3.jsonl
    uv run python scripts/mlx-recognition.py ultra runs/recognition-2026-10-16/audio runs/X/mlx-ultra.jsonl

`model` is a key of translate_core.asr.MODELS or a Hugging Face id / local
directory. Every *.wav with a sibling *.txt is transcribed whole (no rolling
window), one warm-up pass first so kernel compilation is not timed.
"""
import argparse
import json
import pathlib
import time

import numpy as np

from translate_core import audio
from translate_core.asr import MODELS, ParakeetASR


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("model")
    parser.add_argument("folder", type=pathlib.Path)
    parser.add_argument("out", type=pathlib.Path)
    args = parser.parse_args()
    if args.out.exists():
        raise SystemExit(f"{args.out} exists; choose a new file")
    model_id = MODELS.get(args.model, args.model)
    started = time.perf_counter()
    asr = ParakeetASR(model_id)
    asr.transcribe(np.zeros(audio.SAMPLE_RATE, np.float32))
    load_seconds = time.perf_counter() - started
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w") as out:
        for wav in sorted(args.folder.glob("*.wav")):
            reference = wav.with_suffix(".txt")
            if not reference.exists():
                continue
            samples = audio.load(wav, asr.sample_rate)
            started = time.perf_counter()
            words = asr.transcribe(samples)
            seconds = time.perf_counter() - started
            hypothesis = " ".join(w.text for w in words)
            out.write(json.dumps({
                "audio_seconds": len(samples) / asr.sample_rate, "file": wav.name,
                "hypothesis": hypothesis, "load_seconds": load_seconds,
                "model": f"mlx:{args.model}", "recognition_seconds": seconds,
                "reference": reference.read_text().strip(),
                "words": [{"start": w.start, "end": w.end, "text": w.text} for w in words],
            }, ensure_ascii=False) + "\n")
            print(f"{wav.name}: {seconds:.2f}s  {hypothesis}", flush=True)


if __name__ == "__main__":
    main()
