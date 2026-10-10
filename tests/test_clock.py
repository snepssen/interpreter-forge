import pytest

from translate_core.clock import normalise


@pytest.mark.parametrize("source, expected", [
    ("Wir fangen um halb elf an.", "Wir fangen um 10:30 an."),
    ("erst um halb 11 anfangen", "erst um 10:30 anfangen"),
    ("Es ist halb eins.", "Es ist 12:30."),
    ("We beginnen om half negen.", "We beginnen om 8:30."),
    ("Das Konzert ist um drei viertel zehn.", "Das Konzert ist um 9:45."),
    ("um dreiviertel acht", "um 7:45"),
    ("Wir treffen uns um Viertel vor sechs.", "Wir treffen uns um 5:45."),
    ("Ik ben er om kwart voor twaalf.", "Ik ben er om 11:45."),
    ("um 19 Uhr halb 8", "um 19 Uhr 7:30"),
])
def test_times_counted_toward_the_next_hour_become_digits(source, expected):
    assert normalise(source) == expected


@pytest.mark.parametrize("text", [
    "Viertel nach vier",  # counts from the hour: the model gets it right
    "kwart over twee",
    "Das ist nur halb so viel.",  # not a time
    "Ich habe die Hälfte gegessen.",
    "halb voll",
])
def test_other_text_is_left_alone(text):
    assert normalise(text) == text
