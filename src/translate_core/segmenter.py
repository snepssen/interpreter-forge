"""Decides when enough of the speech has arrived to hand a piece on.

The ASR re-reads the uncommitted tail of the stream every hop, so each call to
`Segmenter.step` sees a fresh hypothesis for everything after the commit mark.
Words are only committed once they have come out the same on two consecutive
passes, and only at a point where cutting is safe:

  sentence  a sentence-final mark with recognised speech after it, on both
            passes (aligned word by word; 80% of what precedes must agree). Parakeet ends every window it is given with a full stop,
            and a hesitation mid-clause is enough to earn one ("dass wir.");
            once the speaker carries on, the re-read across the pause drops it.
            So a mark only counts when there is speech on its far side.
  judged    a short pause after stable speech, and the judge (a yes/no from
            the LLM) says what was said can be translated on its own. Saves
            waiting for the next words or a long pause.
  pause     the speaker has been silent long enough that whatever was said is
            all there is.
  clause    a long run without a sentence end; cut at its latest comma, if
            the judge agrees the words before it stand alone.
  force     longer still; cut where the judge accepts (all of it, a comma, a
            wide gap). If it accepts nothing, wait, up to 1.5x as long, then
            cut at the widest gap rather than let lag grow without bound.

The long pause stretches to fit the speaker: the gaps inside committed
sentences tell us how long this person hesitates mid-thought.
"""

import re
from collections import deque
from collections.abc import Callable
from difflib import SequenceMatcher
from dataclasses import dataclass

import numpy as np

from .types import Segment, Word

SENTENCE_END = (".", "?", "!")
TRAILING_OFF = ("...", "…")  # the speaker tailing away, not finishing
CLAUSE_END = (",", ";", ":", "—", "–")
TIMING_SLOP = 0.12  # ASR word times wander about this much between passes
STABLE_SHARE = 0.8  # of a prefix's words that must agree with the last pass


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
    judge_pause: float = 0.4  # silence after which the judge is asked
    judge_tries: int = 3  # candidate cut points put to the judge per decision


class Segmenter:
    def __init__(self, config: SegmenterConfig | None = None, judge: Callable[[str], bool] | None = None):
        self.config = config or SegmenterConfig()
        self.judge = judge  # "can this be translated on its own yet?"
        self._verdicts: dict[str, bool] = {}
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
        agreed = _agreed(self._previous, words)
        while words:
            # The VAD can go on hearing "speech" (noise, a faint voice) long
            # after the last word anyone could transcribe; that is a pause too.
            heard_gap = now - words[-1].end
            cut, reason = self._decide(words, agreed, silence, heard_gap)
            if cut == 0:
                break
            segments.append(self._commit(words[:cut], reason, now))
            words, agreed = words[cut:], agreed[cut:]
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

    def _decide(self, words: list[Word], agreed: list[bool], silence: float,
                heard_gap: float = 0.0) -> tuple[int, str]:
        if max(silence, heard_gap) >= self.long_pause_threshold():
            return len(words), "pause"

        # Latest sentence end with stable speech after it: the mark and the
        # word beyond it both heard the same on both passes.
        stable = _stable(agreed)
        for i in range(stable - 2, -1, -1):
            if (ends_sentence(words[i].text) and agreed[i] and agreed[i + 1]
                    and i + 1 >= self.config.min_words):
                return i + 1, "sentence"

        c = self.config
        if (self.judge and silence >= c.judge_pause and stable == len(words)
                and len(words) >= c.min_words and self._complete(words)):
            return len(words), "judged"

        span = words[-1].end - words[0].start
        if span >= c.soft_segment and (cut := self._first_complete(words, _clause_cuts(words, stable))):
            return cut, "clause"
        if span >= c.max_segment and stable >= 2:
            cuts = _clause_cuts(words, stable) + _gap_cuts(words, stable)
            if not self.judge:
                return (cuts[0] if cuts else stable - 1), "force"
            # No cut it accepts: better late than wrong, up to the cap below.
            if cut := self._first_complete(words, [stable] + cuts):
                return cut, "force"
        if span >= c.max_segment * 1.5:  # never settles: cut what we have
            cuts = _clause_cuts(words, len(words)) + _gap_cuts(words, len(words))
            return (cuts[0] if cuts else len(words)), "force"

        return 0, ""

    def _first_complete(self, words: list[Word], cuts: list[int]) -> int:
        """The first cut whose words stand alone; without a judge, simply the first."""
        if not self.judge:
            return cuts[0] if cuts else 0
        for cut in cuts[: self.config.judge_tries]:
            if self._complete(words[:cut]):
                return cut
        return 0

    def _complete(self, words: list[Word]) -> bool:
        text = " ".join(w.text for w in words)
        if text not in self._verdicts:
            if len(self._verdicts) > 256:
                self._verdicts.clear()
            self._verdicts[text] = self.judge(text)
        return self._verdicts[text]

    def _commit(self, words: list[Word], reason: str, now: float) -> Segment:
        for a, b in zip(words, words[1:]):
            if not ends_sentence(a.text):
                self._gaps.append(max(0.0, b.start - a.end))
        self.mark = words[-1].end
        self._last = words[-1]
        segment = Segment(self._count, list(words), reason, now)
        self._count += 1
        return segment


def _agreed(previous: list[Word], words: list[Word]) -> list[bool]:
    """Which of `words` the previous pass also heard, aligned word by word.

    Alignment rather than a common prefix: in a long window of conversation
    some early word nearly always flickers ("yeah, yeah" / "yeah yeah yeah"),
    and a prefix rule then holds back everything after it.
    """
    matcher = SequenceMatcher(None, [_key(w) for w in previous], [_key(w) for w in words], autojunk=False)
    agreed = [False] * len(words)
    for _, j, n in matcher.get_matching_blocks():
        agreed[j:j + n] = [True] * n
    return agreed


def _stable(agreed: list[bool]) -> int:
    """Longest prefix ending on an agreed word with STABLE_SHARE of its words agreed.

    What flickered inside it is committed as heard last, with the most context.
    """
    best = count = 0
    for n, ok in enumerate(agreed, 1):
        count += ok
        if ok and count >= STABLE_SHARE * n:
            best = n
    return best


def _clause_cuts(words: list[Word], stable: int) -> list[int]:
    """Cuts after clause marks in the first `stable` words, latest first."""
    return [i + 1 for i in range(stable - 2, -1, -1)
            if words[i].text.endswith(CLAUSE_END) and _long_enough(words, i)]


def _gap_cuts(words: list[Word], stable: int) -> list[int]:
    """Cuts at the gaps between the first `stable` words, widest first."""
    gaps = [(words[i + 1].start - words[i].end, i) for i in range(stable - 1) if _long_enough(words, i)]
    return [i + 1 for _, i in sorted(gaps, reverse=True)]


def _long_enough(words: list[Word], i: int) -> bool:
    """A cut after word i keeps at least 40% of the pending speech (or 3 s) in front."""
    span = words[-1].end - words[0].start
    return words[i].end - words[0].start >= min(0.4 * span, 3.0)
