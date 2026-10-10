"""Live interpreting: listen, segment, translate and speak, all at once.

MLX is driven from one thread only, the loop in `LiveInterpreter.run`, and
translation goes first: while a committed piece is being translated, ASR passes
wait. Every moment a committed piece waits is lag the listener hears, while a
delayed ASR pass only delays the next commit, whose translation would queue
behind this one anyway. Measured in real time on an M1 that is 0.6-1.7 s less
median lag than time-slicing the two. The VAD keeps up regardless, and the next
ASR pass simply reads a longer window. Synthesis runs on the CPU in its own thread, and playback is fed
from a queue whose length is the backlog the catch-up policy looks at.

A recording can stand in for the microphone, fed at real-time pace, and the
speaker can be swapped for a recorder: the same loop, the same contention for
the GPU, and a listen-back file at the end.
"""

import queue
import signal
import threading
import time
from collections.abc import Callable, Generator
from dataclasses import dataclass, field

import numpy as np

from .asr import ParakeetASR
from .audio import SAMPLE_RATE
from .pipeline import Backlog, combine
from .segmenter import Segmenter, SegmenterConfig
from .translate import LLMTranslator, echoes
from .tts import PiperTTS
from .types import Segment
from .vad import SileroVAD

BLOCK = SileroVAD.FRAME  # samples per input block: one VAD frame, 32 ms


# -- sources ------------------------------------------------------------------

class Microphone:
    def __init__(self, device: int | str | None = None, keep: list[np.ndarray] | None = None):
        self.device = device
        self.keep = keep  # if given, every block heard is appended here too

    def start(self, push: Callable[[np.ndarray], None]) -> None:
        import sounddevice as sd

        def callback(data, frames, t, status):
            block = data[:, 0].copy()
            if self.keep is not None:
                self.keep.append(block)
            push(block)

        self._stream = sd.InputStream(samplerate=SAMPLE_RATE, channels=1, dtype="float32",
                                      blocksize=BLOCK, device=self.device, callback=callback)
        self._stream.start()

    def done(self) -> bool:
        return False

    def stop(self) -> None:
        self._stream.stop()
        self._stream.close()


class Recording:
    """A recording played into the interpreter at the pace it was spoken."""

    def __init__(self, samples: np.ndarray):
        self.samples = samples
        self._finished = threading.Event()

    def start(self, push: Callable[[np.ndarray], None]) -> None:
        def feed():
            t0 = time.perf_counter()
            for i in range(0, len(self.samples), BLOCK):
                due = t0 + (i + BLOCK) / SAMPLE_RATE
                time.sleep(max(0.0, due - time.perf_counter()))
                push(self.samples[i:i + BLOCK])
            self._finished.set()

        threading.Thread(target=feed, daemon=True).start()

    def done(self) -> bool:
        return self._finished.is_set()

    def stop(self) -> None:
        pass


# -- playback -----------------------------------------------------------------

class Player:
    """Plays clips back to back, or only keeps the schedule when `device` is False.

    Clips are scheduled at max(now, end of the last one); the schedule is what
    the listen-back is built from, and its tail is the backlog.
    """

    def __init__(self, sample_rate: int, clock: Callable[[], float], device: int | str | None | bool = None):
        self.sample_rate, self.clock = sample_rate, clock
        self.placed: list[tuple[float, np.ndarray]] = []
        self._end = 0.0
        self._lock = threading.Lock()
        self._pending: list[np.ndarray] = []
        self._stream = None
        if device is not False:
            import sounddevice as sd
            self._stream = sd.OutputStream(samplerate=sample_rate, channels=1, dtype="float32",
                                           device=device, callback=self._fill)
            self._stream.start()

    def backlog(self) -> float:
        with self._lock:
            return max(0.0, self._end - self.clock())

    def play(self, clip: np.ndarray) -> float:
        with self._lock:
            start = max(self.clock(), self._end)
            self._end = start + len(clip) / self.sample_rate
            self.placed.append((start, clip))
            self._pending.append(clip)
        return start

    def idle(self) -> bool:
        return self.backlog() == 0.0

    def _fill(self, out, frames, t, status):
        out.fill(0)
        filled = 0
        with self._lock:
            while filled < frames and self._pending:
                clip = self._pending[0]
                n = min(frames - filled, len(clip))
                out[filled:filled + n, 0] = clip[:n]
                filled += n
                if n == len(clip):
                    self._pending.pop(0)
                else:
                    self._pending[0] = clip[n:]

    def close(self) -> None:
        if self._stream:
            self._stream.stop()
            self._stream.close()


# -- the loop -----------------------------------------------------------------

@dataclass
class Event:
    """One segment's life, in seconds since the session started."""

    segment: Segment
    translation: str = ""
    silent: str = ""  # why it isn't spoken: "english", "language" (misheard) or "echo"
    brief: bool = False
    pace: float = 1.0
    mt_start: float = 0.0
    mt_end: float = 0.0
    play_start: float = 0.0
    play_seconds: float = 0.0

    @property
    def lag(self) -> float:
        return self.play_start - self.segment.end

    @property
    def lags(self) -> list[float]:
        """The ear-voice span of every piece in it, if pieces were merged."""
        return [self.play_start - end for end in self.segment.parts or [self.segment.end]]


@dataclass
class _Job:
    event: Event
    steps: Generator[None, None, str] = field(repr=False)


class LiveInterpreter:
    def __init__(self, asr: ParakeetASR, translator: LLMTranslator, tts: PiperTTS,
                 judge: Callable[[str], bool] | None = None,
                 gate: Callable[[str], str] | None = None,
                 config: SegmenterConfig | None = None, backlog: Backlog | None = Backlog(),
                 on_segment: Callable[[Segment], None] = lambda s: None,
                 on_event: Callable[[Event], None] = lambda e: None):
        self.asr, self.translator, self.tts, self.judge = asr, translator, tts, judge
        self.gate = gate
        self.config = config or SegmenterConfig()
        self.backlog = backlog
        self.on_segment, self.on_event = on_segment, on_event
        self.events: list[Event] = []

    def run(self, source, device: int | str | None | bool = None, stop: threading.Event | None = None) -> Player:
        """Interpret until the source ends or `stop` is set, then finish what was
        heard. The first Ctrl-C stops listening; a second one abandons the rest."""
        stop = stop or threading.Event()

        def interrupt(signum, frame):
            if stop.is_set():
                raise KeyboardInterrupt
            stop.set()

        previous = signal.signal(signal.SIGINT, interrupt)
        try:
            return self._run(source, device, stop)
        finally:
            signal.signal(signal.SIGINT, previous)

    def _run(self, source, device, stop: threading.Event) -> Player:
        inbox: queue.Queue[np.ndarray] = queue.Queue()
        t0 = time.perf_counter()
        clock = lambda: time.perf_counter() - t0  # noqa: E731
        player = Player(self.tts.sample_rate, clock, device)
        speech: queue.Queue[Event | None] = queue.Queue()
        speaker = threading.Thread(target=self._speak, args=(speech, player), daemon=True)
        speaker.start()

        seg = Segmenter(self.config, self.judge)
        vad = SileroVAD()
        buf = np.zeros(0, np.float32)  # audio from stream sample `base` on
        base = heard = 0  # stream sample index of buf[0]; samples received
        vad_pos = 0  # stream sample index the VAD has reached
        last_hop = 0.0
        waiting: list[Event] = []
        job: _Job | None = None
        ended = False

        source.start(inbox.put)
        try:
            while True:
                source_done = source.done() or stop.is_set()
                while True:  # take whatever audio has arrived
                    try:
                        block = inbox.get_nowait()
                    except queue.Empty:
                        break
                    buf = np.concatenate([buf, block])
                    heard += len(block)
                while vad_pos + BLOCK <= heard:
                    i = vad_pos - base
                    vad.push(buf[i:i + BLOCK], (vad_pos + BLOCK) / SAMPLE_RATE)
                    vad_pos += BLOCK
                now = heard / SAMPLE_RATE

                if not ended and source_done:
                    ended = True
                    for s in self._pass(seg, vad, buf, base, now, flush=True):
                        waiting.append(Event(s))
                elif not ended and now - last_hop >= self.config.hop and job is None and not waiting:
                    last_hop = now
                    for s in self._pass(seg, vad, buf, base, now):
                        waiting.append(Event(s))
                    cut = int(seg.window_start() * SAMPLE_RATE) - SAMPLE_RATE  # keep a second spare
                    if cut > base:
                        buf, base = buf[cut - base:], cut
                    continue

                if job is None and waiting:
                    # Everything waiting goes as one: what the gate turns away set
                    # aside, the rest merged into a single translation.
                    foreign = []
                    for queued in waiting:
                        queued.mt_start = clock()
                        why = self.gate(queued.segment.text) if self.gate else ""
                        if why == "english":
                            self.translator.remember(queued.segment.text)
                        if why:
                            queued.silent, queued.mt_end = why, clock()
                            self.events.append(queued)
                            self.on_event(queued)
                        else:
                            foreign.append(queued.segment)
                    waiting = []
                    if not foreign:
                        continue
                    event = Event(combine(foreign), mt_start=clock())
                    event.brief = bool(self.backlog) and self.backlog.brief(player.backlog())
                    job = _Job(event, self.translator.steps(event.segment.text, event.brief))
                if job is not None:
                    try:
                        next(job.steps)
                    except StopIteration as done:
                        job.event.translation, job.event.mt_end = done.value, clock()
                        if getattr(self.gate, "skips_english", False) and echoes(job.event.segment.text, done.value):
                            job.event.silent = "echo"  # garbled English, repeated: not worth saying
                            self.events.append(job.event)
                            self.on_event(job.event)
                        else:
                            speech.put(job.event)
                        job = None
                    continue

                if ended and speech.unfinished_tasks == 0 and player.idle():
                    break
                time.sleep(0.005)
        finally:
            source.stop()
            speech.put(None)
            speaker.join()
            player.close()
        return player

    def _pass(self, seg: Segmenter, vad: SileroVAD, buf: np.ndarray, base: int, now: float,
              flush: bool = False) -> list[Segment]:
        if vad.last_speech <= seg.mark and not flush:
            return []
        start = seg.window_start()
        i = max(0, int(start * SAMPLE_RATE) - base)
        words = seg.new_words(self.asr.transcribe(buf[i:], (base + i) / SAMPLE_RATE))
        if flush:
            committed = seg.flush(now, words)
        else:
            silence = vad.silence(now)
            committed = seg.step(now, words, silence)
            if not words and silence >= seg.long_pause_threshold():
                seg.advance_idle(now)
        for s in committed:
            self.on_segment(s)
        return committed

    def _speak(self, speech: "queue.Queue[Event | None]", player: Player) -> None:
        while (event := speech.get()) is not None:
            event.pace = self.backlog.pace(player.backlog()) if self.backlog else 1.0
            clip = self.tts.speak(event.translation, pace=event.pace)
            event.play_start = player.play(clip)
            event.play_seconds = len(clip) / self.tts.sample_rate
            self.events.append(event)
            self.on_event(event)
            speech.task_done()
