"""A recording through the live pipeline, on a simulated clock.

The segmenter sees only the audio up to `now`, one hop at a time, so its
decisions are the ones it would make live. Each stage's compute time is
measured for real and laid onto a timeline where every stage is one worker: a
stage starts when its input is ready and it is free, so queueing shows up as
lag. Live, ASR and translation share the GPU and will contend; this does not
model that, so treat its latencies as a lower bound.
"""

from collections.abc import Callable
from time import perf_counter

import numpy as np

from .asr import ParakeetASR
from .audio import SAMPLE_RATE, resample
from .segmenter import Segmenter, SegmenterConfig
from .translate import LLMTranslator
from .tts import PiperTTS
from .types import Result, Segment, Timing
from .vad import SileroVAD


def segment(
    audio: np.ndarray, asr: ParakeetASR, vad: SileroVAD, config: SegmenterConfig,
    judge: Callable[[str], bool] | None = None,
    on_segment: Callable[[Segment, float], None] = lambda s, ms: None,
) -> list[tuple[Segment, float]]:
    """Walk the stream hop by hop; returns each committed segment with its ASR ms."""
    judging = 0.0  # judge time spent this hop; it holds up the decision like ASR does

    def timed(text: str) -> bool:
        nonlocal judging
        t0 = perf_counter()
        verdict = judge(text)
        judging += perf_counter() - t0
        return verdict

    seg = Segmenter(config, timed if judge else None)
    sr, frame, hop = SAMPLE_RATE, SileroVAD.FRAME, int(config.hop * SAMPLE_RATE)
    out: list[tuple[Segment, float]] = []
    vad_pos, asr_free, asr_ms = 0, 0.0, 0.0
    vad.reset()

    for end in range(hop, len(audio) + hop, hop):
        end = min(end, len(audio))
        now = end / sr
        while vad_pos + frame <= end:
            vad.push(audio[vad_pos:vad_pos + frame], (vad_pos + frame) / sr)
            vad_pos += frame
        if vad.last_speech <= seg.mark:
            continue  # nothing said since the last commit

        start = seg.window_start()
        t0 = perf_counter()
        words = seg.new_words(asr.transcribe(audio[int(start * sr):end], start))
        took = perf_counter() - t0
        asr_ms = took * 1000
        asr_free = max(now, asr_free) + took  # a pass can't start before the last one ends

        silence = vad.silence(now)
        judging = 0.0
        committed = seg.step(now, words, silence)
        asr_free += judging
        for s in committed:
            s.decided_at = asr_free
            out.append((s, asr_ms))
            on_segment(s, asr_ms)
        if not words and silence >= seg.long_pause_threshold():
            seg.advance_idle(now)

    for s in seg.flush(len(audio) / sr, seg.pending):
        s.decided_at = asr_free
        out.append((s, asr_ms))
        on_segment(s, asr_ms)
    return out


def interpret(
    segments: list[tuple[Segment, float]], translator: LLMTranslator, tts: PiperTTS,
    on_result: Callable[[Result], None] = lambda r: None,
) -> tuple[list[Result], list[np.ndarray]]:
    """Translate and voice each segment, placing it on the playback clock."""
    results, clips = [], []
    mt_free = tts_free = play_free = 0.0
    for s, asr_ms in segments:
        t = Timing(asr_ms=asr_ms)

        t0 = perf_counter()
        text = translator.translate(s.text)
        t.mt_start = max(s.decided_at, mt_free)
        t.mt_end = mt_free = t.mt_start + (perf_counter() - t0)

        t0 = perf_counter()
        speech = tts.speak(text)
        t.tts_start = max(t.mt_end, tts_free)
        t.tts_end = tts_free = t.tts_start + (perf_counter() - t0)

        seconds = len(speech) / tts.sample_rate
        t.play_start = max(t.tts_end, play_free)
        t.play_end = play_free = t.play_start + seconds

        result = Result(s, text, seconds, t)
        results.append(result)
        clips.append(speech)
        on_result(result)
    return results, clips


def render(source: np.ndarray, results: list[Result], clips: list[np.ndarray], sr: int) -> np.ndarray:
    """Stereo listen-back: left is the speaker, right is the interpreter."""
    left = resample(source, SAMPLE_RATE, sr)
    length = max([len(left)] + [int(r.timing.play_end * sr) + 1 for r in results])
    out = np.zeros((length, 2), np.float32)
    out[:len(left), 0] = left
    for r, clip in zip(results, clips):
        i = int(r.timing.play_start * sr)
        out[i:i + len(clip), 1] += clip
    return out
