import argparse
import json
import statistics
import sys
from dataclasses import asdict
from pathlib import Path

from . import audio
from .asr import DEFAULT_MODEL as ASR_MODEL
from .segmenter import SegmenterConfig
from .translate import DEFAULT_MODEL as MT_MODEL
from .tts import DEFAULT_VOICE
from .types import Result, Segment


def main() -> None:
    p = argparse.ArgumentParser(prog="translate-core", description="Interpret a recording into English.")
    p.add_argument("input", type=Path, help="any audio file ffmpeg can read")
    p.add_argument("--out", type=Path, help="run directory (default: runs/<input name>)")
    p.add_argument("--asr", default=ASR_MODEL)
    p.add_argument("--mt", default=MT_MODEL)
    p.add_argument("--voice", type=Path, default=DEFAULT_VOICE)
    p.add_argument("--segment-only", action="store_true", help="stop after segmentation")
    p.add_argument("--no-judge", action="store_true", help="segment on acoustics and punctuation alone")
    p.add_argument("--no-catch-up", action="store_true", help="never condense or speed up when behind")
    d = SegmenterConfig()
    p.add_argument("--hop", type=float, default=d.hop)
    p.add_argument("--long-pause", type=float, default=d.long_pause)
    p.add_argument("--max-segment", type=float, default=d.max_segment)
    p.add_argument("--no-adapt", action="store_true")
    a = p.parse_args()

    config = SegmenterConfig(hop=a.hop, long_pause=a.long_pause,
                             max_segment=a.max_segment, adapt=not a.no_adapt)
    out = a.out or Path("runs") / a.input.stem
    out.mkdir(parents=True, exist_ok=True)

    # Heavy imports after argparse so --help stays fast.
    import numpy as np

    from .asr import ParakeetASR
    from .pipeline import Backlog, interpret, render, segment
    from .vad import SileroVAD

    source = audio.load(a.input)
    info(f"{a.input.name}: {len(source) / audio.SAMPLE_RATE:.1f} s")

    info(f"loading {a.asr}")
    asr = ParakeetASR(a.asr)
    asr.transcribe(np.zeros(audio.SAMPLE_RATE, np.float32))  # first call compiles kernels

    from .judge import CompletenessJudge
    from .translate import LLMTranslator
    from .tts import PiperTTS

    translator = judge = None
    if not (a.segment_only and a.no_judge):
        info(f"loading {a.mt}")
        translator = LLMTranslator(a.mt)
        translator.translate("Hallo.")  # warm-up
        translator.history.clear()
    if not a.no_judge:
        judge = CompletenessJudge(translator.model, translator.tokenizer)
        judge("Hallo")  # fills the cache with its instructions

    info("segmenting" + ("" if a.no_judge else ", with the judge"))
    segments = segment(source, asr, SileroVAD(), config, judge, on_segment=show_segment)
    if a.segment_only:
        return

    tts = PiperTTS(a.voice)
    tts.speak("Ready.")

    info("interpreting")
    results, clips = interpret(segments, translator, tts, None if a.no_catch_up else Backlog(),
                               on_result=show_result)

    audio.write(out / "listen.wav", render(source, results, clips, tts.sample_rate), tts.sample_rate)
    with open(out / "trace.jsonl", "w") as f:
        for r in results:
            f.write(json.dumps(trace(r), ensure_ascii=False) + "\n")
    summary = summarise(results, len(source) / audio.SAMPLE_RATE)
    (out / "summary.txt").write_text(summary + "\n")
    print("\n" + summary)
    info(f"wrote {out}/listen.wav (L: speaker, R: interpreter), trace.jsonl, summary.txt")


def info(msg: str) -> None:
    print(f"· {msg}", file=sys.stderr, flush=True)


def show_segment(s: Segment, asr_ms: float) -> None:
    print(f"[{s.start:6.2f}–{s.end:6.2f}] {s.reason:<8} wait {s.decided_at - s.end:4.1f}s  "
          f"asr {asr_ms:4.0f}ms  │ {s.text}", flush=True)


def show_result(r: Result) -> None:
    t = r.timing
    print(f"  #{r.segment.index:<3} mt {(t.mt_end - t.mt_start) * 1000:5.0f}ms  "
          f"tts {(t.tts_end - t.tts_start) * 1000:4.0f}ms  "
          f"plays {t.play_start:6.2f}s  lag {r.lag:4.1f}s{catch_up(r)}  → {r.translation}", flush=True)


def catch_up(r: Result) -> str:
    marks = (["brief"] if r.brief else []) + ([f"x{r.pace:.2f}"] if r.pace > 1 else [])
    return f"  [{' '.join(marks)}]" if marks else ""


def trace(r: Result) -> dict:
    s = r.segment
    return {
        "index": s.index, "reason": s.reason, "start": s.start, "end": s.end,
        "decided_at": s.decided_at, "source": s.text, "translation": r.translation,
        "audio_seconds": r.audio_seconds, "lag": r.lag, "brief": r.brief, "pace": r.pace,
        **asdict(r.timing),
        "words": [asdict(w) for w in s.words],
    }


def summarise(results: list[Result], duration: float) -> str:
    if not results:
        return "no segments"
    lags = [r.lag for r in results]
    waits = [r.segment.decided_at - r.segment.end for r in results]
    queued = [r.timing.play_start - r.timing.tts_end for r in results]
    ms = lambda xs: f"{statistics.mean(xs) * 1000:.0f} ms"
    reasons = {k: sum(r.segment.reason == k for r in results) for k in ("sentence", "judged", "pause", "clause", "force", "flush")}
    return "\n".join([
        f"segments      {len(results)}  ({', '.join(f'{k} {v}' for k, v in reasons.items() if v)})",
        f"lag           median {statistics.median(lags):.1f} s, max {max(lags):.1f} s  (source segment end → playback start)",
        f"commit wait   median {statistics.median(waits):.1f} s  (segment end → decision)",
        f"asr pass      mean {statistics.mean(r.timing.asr_ms for r in results):.0f} ms",
        f"translate     mean {ms([r.timing.mt_end - r.timing.mt_start for r in results])}",
        f"speak         mean {ms([r.timing.tts_end - r.timing.tts_start for r in results])}",
        f"queued        max {max(queued):.1f} s  (ready → playing, i.e. backlog)",
        f"catching up   {sum(r.brief for r in results)} brief, {sum(r.pace > 1 for r in results)} faster",
        f"speech        source {duration:.1f} s, interpreter {sum(r.audio_seconds for r in results):.1f} s",
    ])
