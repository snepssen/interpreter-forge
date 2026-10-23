import pytest

from cases import load, snake, words
from translate_core.segmenter import Segmenter, SegmenterConfig
from translate_core.types import Word

CASES = load("segmenter")["cases"]


class FakeJudge:
    """Complete when the text ends in one of `endings`; keeps what it was asked."""

    def __init__(self, endings):
        self.endings, self.asked = tuple(endings), []

    def __call__(self, text: str) -> bool:
        self.asked.append(text)
        return text.strip(".,").endswith(self.endings)


@pytest.mark.parametrize("case", CASES, ids=[c["name"] for c in CASES])
def test_segmenter_case(case):
    config = SegmenterConfig(adapt=False, **{snake(k): v for k, v in case.get("config", {}).items()})
    judge = FakeJudge(case["judge"]) if "judge" in case else None
    s = Segmenter(config, judge=judge)
    if "startMark" in case:
        s.mark = case["startMark"]
    for i, step in enumerate(case["steps"]):
        out = s.step(step["now"], words(step["words"]), silence=step["silence"])
        if "expect" in step:
            assert len(out) == len(step["expect"]), f"step {i}: {out}"
            for seg, want in zip(out, step["expect"]):
                for field, value in want.items():
                    assert getattr(seg, field) == value, f"step {i}: {seg}"
        if "asked" in step:
            assert judge.asked == step["asked"], f"step {i}"
    after = case.get("after", {})
    if "mark" in after:
        assert s.mark == pytest.approx(after["mark"])
    if "pending" in after:
        assert [w.text for w in s.pending] == after["pending"]
    if "asked" in after:
        assert judge.asked == after["asked"]
    if "newWords" in case:
        nw = case["newWords"]
        base = s.mark if nw.get("fromMark") else 0.0
        heard = [Word(t, base + a, base + b) for t, a, b in nw["words"]]
        assert [w.text for w in s.new_words(heard)] == nw["expect"]


def test_pauses_stretch_for_a_hesitant_speaker():
    # Compares thresholds, not outputs, so it stays here rather than in cases/.
    s = Segmenter(SegmenterConfig(adapt=True))
    base = s.long_pause_threshold()
    for i in range(10):
        s.step(0.0, words([{"text": "ein sehr langsamer Satz.", "start": i * 10, "step": 1.2}]), silence=9.0)
    assert base < s.long_pause_threshold() <= s.config.max_long_pause
