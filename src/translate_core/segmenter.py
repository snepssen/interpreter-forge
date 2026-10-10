"""Decides when enough of the speech has arrived to hand a piece on.

The ASR re-reads the uncommitted tail of the stream every hop, so each call to
`Segmenter.step` sees a fresh hypothesis for everything after the commit mark.
Words are only committed once they have come out the same on two consecutive
passes, and only at a point where cutting is safe:

  sentence  a sentence-final mark with recognised speech after it, on both
            passes. Parakeet ends every window it is given with a full stop,
            and a hesitation mid-clause is enough to earn one ("dass wir.");
            once the speaker carries on, the re-read across the pause drops it.
            So a mark only counts when there is speech on its far side.
  pause     the speaker has been silent long enough that whatever was said is
            all there is.
  clause    a long run without a sentence end; cut at its latest comma.
  force     longer still and no comma; cut at the widest gap rather than
            let lag grow without bound.

The long pause stretches to fit the speaker: the gaps inside committed
sentences tell us how long this person hesitates mid-thought.
"""

import re
from collections import deque
from dataclasses import dataclass

import numpy as np

from .types import Segment, Word

SENTENCE_END = (".", "?", "!")
TRAILING_OFF = ("...", "…")  # the speaker tailing away, not finishing
CLAUSE_END = (",", ";", ":", "—", "–")
TIMING_SLOP = 0.12  # ASR word times wander about this much between passes


def ends_sentence(text: str) -> bool:
    return text.endswith(SENTENCE_END) and not text.endswith(TRAILING_OFF)


def _key(w: Word) -> tuple[str, bool]:
    """What must agree between passes: the word, and whether it ends a sentence.

    Case and commas may flicker; a sentence end moving is a real change.
    """
    return re.sub(r"\W", "", w.text.lower()), ends_sentence(w.text)


@dataclass
class SegmenterConfig:
    hop: float = 0.5  # seconds of audio between ASR passes
    left_context: float = 0.5  # committed audio re-fed ahead of the mark
    long_pause: float = 1.4  # silence that commits everything said so far
    soft_segment: float = 6.0  # uncommitted speech past which a comma will do
    max_segment: float = 10.0  # uncommitted speech that forces a cut anywhere
    min_words: int = 3  # shorter sentences wait to join the next one
    adapt: bool = True  # stretch the long pause to the speaker's hesitations
    max_long_pause: float = 3.0  # ceiling on the adapted long pause


class Segmenter:
    def __init__(self, config: SegmenterConfig | None = None):
        self.config = config or SegmenterConfig()
        self.mark = 0.0  # stream time up to which everything is committed
        self._previous: list[Word] = []
        self._last: Word | None = None  # the last committed word
        self._gaps: deque[float] = deque(maxlen=200)
        self._count = 0

    def long_pause_threshold(self) -> float:
        c = self.config
        if not c.adapt or len(self._gaps) < 8:
            return c.long_pause
        return min(max(c.long_pause, float(np.percentile(self._gaps, 98)) * 1.6), c.max_long_pause)

    @property
    def pending(self) -> list[Word]:
        """The latest hypothesis for everything not yet committed."""
        return list(self._previous)

    def window_start(self) -> float:
        """Where the next ASR window should begin, in stream seconds."""
        return max(0.0, self.mark - self.config.left_context)

    def new_words(self, words: list[Word]) -> list[Word]:
        """Drop the re-recognised left context, keeping words past the mark."""
        kept = [w for w in words if (w.start + w.end) / 2 >= self.mark - TIMING_SLOP]
        if kept and self._last and (
            kept[0].start < self.mark - TIMING_SLOP  # begins inside the committed word
            or (kept[0].start < self.mark and _key(kept[0])[0] == _key(self._last)[0])
        ):
            kept = kept[1:]  # the committed word again, re-heard or re-timed
        return kept

    def step(self, now: float, words: list[Word], silence: float) -> list[Segment]:
        """Advance with the latest hypothesis for the uncommitted tail.

        `words` must already be filtered by `new_words`; `silence` is how long
        the VAD has heard no speech, as of `now`.
        """
        segments: list[Segment] = []
        stable = _common_prefix(self._previous, words)
        while words:
            cut, reason = self._decide(words, stable, silence)
            if cut == 0:
                break
            segments.append(self._commit(words[:cut], reason, now))
            words, stable = words[cut:], max(0, stable - cut)
        self._previous = list(words)
        return segments

    def flush(self, now: float, words: list[Word]) -> list[Segment]:
        """End of stream: commit whatever is left."""
        self._previous = []
        return [self._commit(words, "flush", now)] if words else []

    def advance_idle(self, now: float) -> None:
        """Slide the mark through silence so ASR windows stay short."""
        if not self._previous:
            self.mark = max(self.mark, now - self.config.left_context)

    def _decide(self, words: list[Word], stable: int, silence: float) -> tuple[int, str]:
        if silence >= self.long_pause_threshold():
            return len(words), "pause"

        # Latest sentence end with stable speech after it.
        for i in range(stable - 2, -1, -1):
            if ends_sentence(words[i].text) and i + 1 >= self.config.min_words:
                return i + 1, "sentence"

        span = words[-1].end - words[0].start
        if span >= self.config.soft_segment and (cut := _clause_cut(words, stable)):
            return cut, "clause"
        if span >= self.config.max_segment and stable >= 2:
            return _force_cut(words, stable), "force"
        if span >= self.config.max_segment * 1.5:  # never settles: cut what we have
            return _force_cut(words, len(words)), "force"

        return 0, ""

    def _commit(self, words: list[Word], reason: str, now: float) -> Segment:
        for a, b in zip(words, words[1:]):
            if not ends_sentence(a.text):
                self._gaps.append(max(0.0, b.start - a.end))
        self.mark = words[-1].end
        self._last = words[-1]
        segment = Segment(self._count, list(words), reason, now)
        self._count += 1
        return segment


def _common_prefix(a: list[Word], b: list[Word]) -> int:
    n = 0
    for x, y in zip(a, b):
        if _key(x) != _key(y):
            break
        n += 1
    return n


def _clause_cut(words: list[Word], stable: int) -> int:
    """Cut after the latest clause mark in the stable words, if one leaves a real piece."""
    for i in range(stable - 2, -1, -1):
        if words[i].text.endswith(CLAUSE_END) and _long_enough(words, i):
            return i + 1
    return 0


def _force_cut(words: list[Word], stable: int) -> int:
    """Cut inside the first `stable` words: a clause mark, else the widest gap."""
    if cut := _clause_cut(words, stable):
        return cut
    gaps = [(words[i + 1].start - words[i].end, i) for i in range(stable - 1) if _long_enough(words, i)]
    return max(gaps)[1] + 1 if gaps else max(stable - 1, 1)


def _long_enough(words: list[Word], i: int) -> bool:
    """A cut after word i keeps at least 40% of the pending speech (or 3 s) in front."""
    span = words[-1].end - words[0].start
    return words[i].end - words[0].start >= min(0.4 * span, 3.0)
