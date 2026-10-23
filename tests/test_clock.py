import pytest

from cases import load
from translate_core.clock import normalise

CASES = load("clock")


@pytest.mark.parametrize("source, expected", CASES["becomeDigits"])
def test_times_counted_toward_the_next_hour_become_digits(source, expected):
    assert normalise(source) == expected


@pytest.mark.parametrize("text", CASES["leftAlone"])
def test_other_text_is_left_alone(text):
    assert normalise(text) == text
