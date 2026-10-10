from translate_core.segmenter import Segmenter, SegmenterConfig
from translate_core.types import Word


def words(text: str, start: float = 0.0, step: float = 0.4) -> list[Word]:
    """One word per `step` seconds, each lasting 0.3 s."""
    return [Word(t, start + i * step, start + i * step + 0.3) for i, t in enumerate(text.split())]


def segmenter(**kw) -> Segmenter:
    return Segmenter(SegmenterConfig(adapt=False, **kw))


def test_full_stop_at_window_end_is_not_trusted():
    s = segmenter()
    hyp = words("Ich wollte nur sagen.")
    assert s.step(2.0, hyp, silence=0.0) == []
    assert s.step(2.5, hyp, silence=0.0) == []


def test_sentence_end_with_stable_speech_after_it_commits():
    s = segmenter()
    hyp = words("Ich wollte nur sagen. Dass wir")
    assert s.step(2.5, hyp, silence=0.0) == []  # seen once: not yet stable
    [seg] = s.step(3.0, hyp, silence=0.0)
    assert seg.text == "Ich wollte nur sagen." and seg.reason == "sentence"
    assert s.mark == hyp[3].end
    assert [w.text for w in s.pending] == ["Dass", "wir"]


def test_full_stop_that_moves_is_not_stable():
    s = segmenter()
    s.step(2.5, words("Ich wollte nur sagen. Dass wir"), silence=0.0)
    assert s.step(3.0, words("Ich wollte nur sagen, dass wir morgen"), silence=0.0) == []


def test_hesitation_after_a_final_full_stop_does_not_confirm_it():
    # "dass wir." at a mid-clause pause: the verb has not arrived yet.
    s = segmenter()
    hyp = words("Ich wollte sagen, dass wir.")
    s.step(2.0, hyp, silence=0.0)
    assert s.step(3.0, hyp, silence=1.1) == []


def test_case_and_comma_flicker_still_counts_as_stable():
    s = segmenter()
    s.step(2.5, words("ich wollte nur sagen. Dass wir"), silence=0.0)
    [seg] = s.step(3.0, words("Ich wollte nur, sagen. dass wir"), silence=0.0)
    assert seg.text == "Ich wollte nur, sagen."


def test_mid_sentence_hesitation_waits():
    s = segmenter()
    hyp = words("Also ich wollte eigentlich")
    s.step(2.0, hyp, silence=0.0)
    assert s.step(3.0, hyp, silence=1.0) == []  # longer than `pause`, shorter than `long_pause`


def test_long_pause_commits_everything():
    s = segmenter()
    hyp = words("Also ich wollte eigentlich")
    [seg] = s.step(4.0, hyp, silence=1.5)
    assert seg.reason == "pause" and seg.text == "Also ich wollte eigentlich"
    assert s.pending == []


def test_short_sentence_waits_to_join_the_next():
    s = segmenter(min_words=3)
    hyp = words("Ja. Das ist")
    s.step(1.5, hyp, silence=0.0)
    assert s.step(2.0, hyp, silence=0.0) == []
    hyp = words("Ja. Das ist gut. Und dann")
    s.step(2.5, hyp, silence=0.0)
    [seg] = s.step(3.0, hyp, silence=0.0)
    assert seg.text == "Ja. Das ist gut."


def test_earlier_sentence_end_commits_when_the_latest_is_unconfirmed():
    s = segmenter()
    hyp = words("Das ist ein Satz. Und noch einer.")
    s.step(3.0, hyp, silence=0.0)
    [seg] = s.step(3.5, hyp, silence=0.0)
    assert seg.text == "Das ist ein Satz."


def test_run_on_speech_is_cut_at_the_last_comma():
    s = segmenter(soft_segment=4.0)
    hyp = words("wir haben das gemacht, weil es nötig war, und dann haben wir noch")
    s.step(5.0, hyp, silence=0.0)
    [seg] = s.step(5.5, hyp, silence=0.0)
    assert seg.reason == "clause" and seg.text == "wir haben das gemacht, weil es nötig war,"


def test_comma_too_early_to_leave_a_real_piece_is_skipped():
    s = segmenter(soft_segment=4.0)
    hyp = words("Ja, also wir haben das gemacht weil es nötig war und dann haben wir noch")
    s.step(5.0, hyp, silence=0.0)
    assert s.step(5.5, hyp, silence=0.0) == []


def test_run_on_speech_without_commas_is_cut_at_the_widest_gap():
    s = segmenter(soft_segment=3.0, max_segment=4.0)
    hyp = words("eins zwei drei vier fünf sechs sieben") + words("acht neun zehn elf zwölf", start=3.6)
    s.step(6.0, hyp, silence=0.0)
    [seg] = s.step(6.5, hyp, silence=0.0)
    assert seg.reason == "force" and seg.text == "eins zwei drei vier fünf sechs sieben"


def test_left_context_words_are_dropped():
    s = segmenter()
    s.mark = 1.0
    hyp = [Word("alt.", 0.6, 0.95), Word("neu", 1.1, 1.4)]
    assert [w.text for w in s.new_words(hyp)] == ["neu"]


def test_next_word_survives_timing_drift_but_committed_word_does_not_repeat():
    s = segmenter()
    hyp = words("Das ist ein Satz. Der nächste")
    s.step(2.5, hyp, silence=0.0)
    s.step(3.0, hyp, silence=0.0)  # commits up to "Satz.", mark = 1.5
    drifted = [Word("Satz.", 1.25, 1.45), Word("Der", 1.42, 1.6), Word("nächste", 1.7, 2.0)]
    assert [w.text for w in s.new_words(drifted)] == ["Der", "nächste"]


def test_pauses_stretch_for_a_hesitant_speaker():
    s = Segmenter(SegmenterConfig(adapt=True))
    base = s.long_pause_threshold()
    for i in range(10):
        s.step(0.0, words("ein sehr langsamer Satz.", start=i * 10, step=1.2), silence=9.0)
    assert base < s.long_pause_threshold() <= s.config.max_long_pause


def test_committed_word_reheard_differently_is_not_repeated():
    # "mir" committed, then the next window hears its tail as "Mehr".
    s = segmenter()
    s.step(3.0, words("Meldet sich bitte bei mir"), silence=2.0)
    reheard = [Word("Mehr.", s.mark - 0.25, s.mark + 0.05), Word("Danke.", s.mark + 1.5, s.mark + 1.9)]
    assert [w.text for w in s.new_words(reheard)] == ["Danke."]


class FakeJudge:
    """Complete when the text ends in one of `complete_endings`; counts calls."""

    def __init__(self, *complete_endings: str):
        self.endings, self.asked = complete_endings, []

    def __call__(self, text: str) -> bool:
        self.asked.append(text)
        return text.rstrip(".,").endswith(self.endings)


def test_judge_commits_a_complete_thought_at_a_short_pause():
    s = Segmenter(SegmenterConfig(adapt=False), judge=FakeJudge("anfangen"))
    hyp = words("dass wir um zehn anfangen.")
    assert s.step(2.5, hyp, silence=0.0) == []
    [seg] = s.step(3.0, hyp, silence=0.5)
    assert seg.reason == "judged"


def test_judge_holds_a_clause_still_waiting_for_its_verb():
    s = Segmenter(SegmenterConfig(adapt=False), judge=FakeJudge("anfangen"))
    hyp = words("dass wir morgen nicht um neun.")
    s.step(2.5, hyp, silence=0.0)
    assert s.step(3.0, hyp, silence=0.5) == []


def test_judge_is_not_asked_about_unstable_words_or_twice_about_the_same():
    judge = FakeJudge()
    s = Segmenter(SegmenterConfig(adapt=False), judge=judge)
    s.step(2.5, words("dass wir morgen"), silence=0.5)
    assert judge.asked == []
    hyp = words("dass wir morgen nicht")
    s.step(3.0, hyp, silence=0.5)
    s.step(3.5, hyp, silence=0.5)
    s.step(4.0, hyp, silence=0.6)
    assert judge.asked == ["dass wir morgen nicht"]


def test_judge_vetoes_a_comma_cut_that_would_strand_the_verb():
    s = Segmenter(SegmenterConfig(adapt=False, soft_segment=4.0), judge=FakeJudge("gemacht"))
    hyp = words("weil wir das morgen um neun, und nicht später gemacht haben wollten und so")
    s.step(5.0, hyp, silence=0.0)
    assert s.step(5.5, hyp, silence=0.0) == []


def test_forced_cut_prefers_the_point_the_judge_accepts():
    judge = FakeJudge("gemacht")
    s = Segmenter(SegmenterConfig(adapt=False, soft_segment=3.0, max_segment=4.0), judge=judge)
    # Widest gap is after "es" (0.5 s); the judge only accepts the cut after "gemacht" (0.3 s).
    hyp = (words("wir haben das alles gestern gemacht") + words("weil es", start=2.6)
           + words("nötig war und dann noch", start=3.8))
    s.step(6.0, hyp, silence=0.0)
    [seg] = s.step(6.5, hyp, silence=0.0)
    assert seg.reason == "force" and seg.text == "wir haben das alles gestern gemacht"


def test_forced_cut_waits_rather_than_cut_where_the_judge_refuses():
    s = Segmenter(SegmenterConfig(adapt=False, soft_segment=3.0, max_segment=4.0), judge=FakeJudge())
    hyp = words("wir haben das alles gestern gemacht weil es nötig war und dann noch so")  # 5.5 s
    s.step(6.0, hyp, silence=0.0)
    assert s.step(6.5, hyp, silence=0.0) == []
    hyp = words("wir haben das alles gestern gemacht weil es nötig war und dann noch so und weiter")  # 6.3 s
    s.step(7.0, hyp, silence=0.0)
    [seg] = s.step(7.5, hyp, silence=0.0)  # past 1.5 x max_segment
    assert seg.reason == "force"
