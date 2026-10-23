import pytest

from cases import load
from translate_core.translate import echoes

CASES = load("echoes")


@pytest.mark.parametrize("source, translation", CASES["echoes"])
def test_garbled_english_repeated_is_an_echo(source, translation):
    assert echoes(source, translation)


@pytest.mark.parametrize("source, translation", CASES["notEchoes"])
def test_a_real_translation_is_not(source, translation):
    assert not echoes(source, translation)
