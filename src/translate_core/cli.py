import argparse
import json
import statistics
import sys
import threading
import time
from dataclasses import asdict
from pathlib import Path

from . import audio
from .asr import DEFAULT_MODEL as ASR_MODEL
from .segmenter import SegmenterConfig
from .translate import DEFAULT_MODEL as MT_MODEL
from .tts import DEFAULT_VOICE
from .types import Result, Segment


def main() -> None:
    p = argparse.ArgumentParser(prog="translate-core", description="Interpret speech into English, locally.")
    sub = p.add_subparsers(dest="command", required=True)

    f = sub.add_parser("file", help="a recording through the pipeline on a simulated clock")
    f.add_argument("inputs", type=Path, nargs="+", metavar="input", help="audio files ffmpeg can read (wav, m4a, mp3, ...)")
    f.add_argument("--segment-only", action="store_true", help="stop after segmentation")

    live = sub.add_parser("live", help="microphone to headphones (or a recording, in real time)")
    live.add_argument("--from", dest="input", type=Path, help="feed this recording in at real-time pace instead of the mic")
    live.add_argument("--play", action="store_true", help="with --from: also play the interpreter aloud")
    live.add_argument("--mic", help="input device (index or name); default: the system's")
    live.add_argument("--speaker", help="output device (index or name); default: the system's")

    for s in (f, live):
        s.add_argument("--out", type=Path, help="run directory (default: runs/<name>; with several inputs, the parent)")
        s.add_argument("--asr", default=ASR_MODEL)
        s.add_argument("--mt", default=MT_MODEL)
        s.add_argument("--voice", type=Path, default=DEFAULT_VOICE)
        s.add_argument("--no-judge", action="store_true", help="segment on acoustics and punctuation alone")
        s.add_argument("--no-catch-up", action="store_true", help="never condense or speed up when behind")
        d = SegmenterConfig()
        s.add_argument("--hop", type=float, default=d.hop)
        s.add_argument("--long-pause", type=float, default=d.long_pause)
        s.add_argument("--max-segment", type=float, default=d.max_segment)
        s.add_argument("--no-adapt", action="store_true")

    a = p.parse_args()
    a.config = SegmenterConfig(hop=a.hop, long_pause=a.long_pause, max_segment=a.max_segment, adapt=not a.no_adapt)
    (run_file if a.command == "file" else run_live)(a)


# -- shared -------------------------------------------------------------------

def load_models(a, need_translator: bool = True):
    import numpy as np

    from .asr import ParakeetASR
    from .judge import CompletenessJudge
    from .translate import LLMTranslator
    from .tts import PiperTTS

    info(f"loading {a.asr}")
    asr = ParakeetASR(a.asr)
    asr.transcribe(np.zeros(audio.SAMPLE_RATE, np.float32))  # first call compiles kernels

    translator = judge = tts = None
    if need_translator or not a.no_judge:
        info(f"loading {a.mt}")
        translator = LLMTranslator(a.mt)
        translator.translate("Hallo.")  # warm-up
        translator.reset()
    if not a.no_judge:
        judge = CompletenessJudge(translator.model, translator.tokenizer)
        judge("Hallo")  # fills the cache with its instructions
    if need_translator:
        tts = PiperTTS(a.voice)
        tts.speak("Ready.")
    return asr, translator, judge, tts


def backlog(a):
    from .pipeline import Backlog
    return None if a.no_catch_up else Backlog()


def device(value: str | None) -> int | str | None:
    return int(value) if value and value.isdigit() else value


def info(msg: str) -> None:
    print(f"· {msg}", file=sys.stderr, flush=True)


def catch_up(brief: bool, pace: float) -> str:
    marks = (["brief"] if brief else []) + ([f"x{pace:.2f}"] if pace > 1 else [])
    return f"  [{' '.join(marks)}]" if marks else ""


# -- file ---------------------------------------------------------------------

def run_file(a) -> None:
    from .pipeline import interpret, render, segment
    from .vad import SileroVAD

    asr, translator, judge, tts = load_models(a, need_translator=not a.segment_only)
    table = []
    for path in a.inputs:
        out = (a.out / path.stem if len(a.inputs) > 1 else a.out) if a.out else Path("runs") / path.stem
        out.mkdir(parents=True, exist_ok=True)
        source = audio.load(path)
        seconds = len(source) / audio.SAMPLE_RATE
        info(f"{path.name}: {seconds:.1f} s, segmenting" + ("" if a.no_judge else " with the judge"))
        segments = segment(source, asr, SileroVAD(), a.config, judge, on_segment=show_segment)
        if a.segment_only:
            continue

        info("interpreting")
        translator.reset()
        results, clips = interpret(segments, translator, tts, backlog(a), on_result=show_result)

        placed = [(r.timing.play_start, clip) for r, clip in zip(results, clips)]
        audio.write(out / "listen.wav", render(source, placed, tts.sample_rate), tts.sample_rate)
        with open(out / "trace.jsonl", "w") as fh:
            for r in results:
                fh.write(json.dumps(trace(r), ensure_ascii=False) + "\n")
        summary = summarise(results, seconds)
        (out / "summary.txt").write_text(summary + "\n")
        print("\n" + summary + "\n")
        info(f"wrote {out}/listen.wav (L: speaker, R: interpreter), trace.jsonl, summary.txt")
        if results:
            lags = [r.lag for r in results]
            table.append((path.name, seconds, len(results), statistics.median(lags), max(lags)))

    if len(table) > 1:
        width = max(len(row[0]) for row in table)
        print(f"{'':{width}}  length  pieces  median lag  max lag")
        for name, seconds, n, median, worst in table:
            print(f"{name:{width}}  {seconds:5.1f}s  {n:6d}  {median:9.1f}s  {worst:6.1f}s")


def show_segment(s: Segment, asr_ms: float) -> None:
    print(f"[{s.start:6.2f}–{s.end:6.2f}] {s.reason:<8} wait {s.decided_at - s.end:4.1f}s  "
          f"asr {asr_ms:4.0f}ms  │ {s.text}", flush=True)


def show_result(r: Result) -> None:
    t = r.timing
    print(f"  #{r.segment.index:<3} mt {(t.mt_end - t.mt_start) * 1000:5.0f}ms  "
          f"tts {(t.tts_end - t.tts_start) * 1000:4.0f}ms  "
          f"plays {t.play_start:6.2f}s  lag {r.lag:4.1f}s{catch_up(r.brief, r.pace)}  → {r.translation}",
          flush=True)


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
    ms = lambda xs: f"{statistics.mean(xs) * 1000:.0f} ms"  # noqa: E731
    reasons = {k: sum(r.segment.reason == k for r in results)
               for k in ("sentence", "judged", "pause", "clause", "force", "flush")}
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


# -- live ---------------------------------------------------------------------

def run_live(a) -> None:
    import numpy as np

    from .live import Event, LiveInterpreter, Microphone, Recording
    from .pipeline import render

    name = f"live-{a.input.stem}" if a.input else time.strftime("live-%Y%m%d-%H%M%S")
    out = a.out or Path("runs") / name
    asr, translator, judge, tts = load_models(a)

    heard: list[np.ndarray] = []
    if a.input:
        samples = audio.load(a.input)
        source = Recording(samples)
        speaker = device(a.speaker) if a.play else False
    else:
        source = Microphone(device(a.mic), keep=heard)
        speaker = device(a.speaker)

    def show_live_segment(s: Segment) -> None:
        print(f"[{s.start:6.2f}–{s.end:6.2f}] {s.reason:<8} │ {s.text}", flush=True)

    def show_event(e: Event) -> None:
        print(f"  #{e.segment.index:<3} mt {(e.mt_end - e.mt_start) * 1000:5.0f}ms  plays {e.play_start:6.2f}s  "
              f"lag {e.lag:4.1f}s{catch_up(e.brief, e.pace)}  → {e.translation}", flush=True)

    interpreter = LiveInterpreter(asr, translator, tts, judge, a.config, backlog(a),
                                  on_segment=show_live_segment, on_event=show_event)
    stop = threading.Event()
    info("listening; Ctrl-C to stop" if not a.input else f"playing {a.input.name} in real time")
    player = interpreter.run(source, speaker, stop)
    if not a.input:
        info("stopped; finishing what was heard")

    events = interpreter.events
    out.mkdir(parents=True, exist_ok=True)
    spoken = samples if a.input else np.concatenate(heard or [np.zeros(1, np.float32)])
    audio.write(out / "listen.wav", render(spoken, player.placed, tts.sample_rate), tts.sample_rate)
    with open(out / "trace.jsonl", "w") as fh:
        for e in events:
            fh.write(json.dumps({
                "index": e.segment.index, "reason": e.segment.reason, "start": e.segment.start,
                "end": e.segment.end, "source": e.segment.text, "translation": e.translation,
                "brief": e.brief, "pace": e.pace, "mt_start": e.mt_start, "mt_end": e.mt_end,
                "play_start": e.play_start, "play_seconds": e.play_seconds, "lag": e.lag,
            }, ensure_ascii=False) + "\n")
    if events:
        lags = [e.lag for e in events]
        summary = "\n".join([
            f"segments      {len(events)}",
            f"lag           median {statistics.median(lags):.1f} s, max {max(lags):.1f} s  (source segment end → playback start)",
            f"translate     mean {statistics.mean(e.mt_end - e.mt_start for e in events) * 1000:.0f} ms  (wall, interleaved with listening)",
            f"catching up   {sum(e.brief for e in events)} brief, {sum(e.pace > 1 for e in events)} faster",
        ])
        (out / "summary.txt").write_text(summary + "\n")
        print("\n" + summary)
    info(f"wrote {out}/listen.wav (L: speaker, R: interpreter), trace.jsonl")
