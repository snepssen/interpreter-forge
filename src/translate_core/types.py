from dataclasses import dataclass, field


@dataclass(frozen=True)
class Word:
    """One recognised word, timed in seconds from the start of the stream."""

    text: str
    start: float
    end: float


@dataclass
class Segment:
    """A run of words the segmenter has committed: passed on, never revised."""

    index: int
    words: list[Word]
    reason: str  # "sentence", "judged", "pause", "clause", "force" or "flush"
    decided_at: float  # stream time at which the commit decision existed
    parts: list[float] = field(default_factory=list)  # if merged: where each piece in it ended

    @property
    def text(self) -> str:
        return " ".join(w.text for w in self.words)

    @property
    def start(self) -> float:
        return self.words[0].start

    @property
    def end(self) -> float:
        return self.words[-1].end


@dataclass
class Timing:
    """Where a segment sat on each stage's clock, all in stream seconds."""

    asr_ms: float = 0.0
    mt_start: float = 0.0
    mt_end: float = 0.0
    tts_start: float = 0.0
    tts_end: float = 0.0
    play_start: float = 0.0
    play_end: float = 0.0


@dataclass
class Result:
    segment: Segment
    translation: str
    audio_seconds: float
    timing: Timing = field(default_factory=Timing)
    brief: bool = False  # translated for the gist, to catch up
    pace: float = 1.0  # spoken faster than normal by this factor
    silent: str = ""  # why it isn't spoken: "english", "language" (misheard) or "echo"

    @property
    def lag(self) -> float:
        """Ear-voice span: source segment ends -> its translation starts playing."""
        return self.timing.play_start - self.segment.end

    @property
    def lags(self) -> list[float]:
        """The ear-voice span of every piece in it, if pieces were merged."""
        return [self.timing.play_start - end for end in self.segment.parts or [self.segment.end]]
