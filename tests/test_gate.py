import pytest

from translate_core.judge import evidence

HERE = ["en", "pl", "hu", "nl"]


@pytest.mark.parametrize("text", [
    "A tudom, de a nyelvedől.",  # ő: Hungarian, however garbled the rest
    "Nem tudom, volám használt that volami.",  # "nem", "tudom"
    "Chciałem poprosić o zapalniczkę.",  # ł, ę
    "Ale tego nie wiesz.",  # "nie", "tego", "wiesz": no Polish letters at all
    "Dat is gezellig, toch?",
])
def test_signs_of_an_expected_language_let_it_through(text):
    assert evidence(text, HERE) is True


@pytest.mark.parametrize("text", [
    "Почему единицы на подниму?",  # Polish written down as Russian
    "Não é nada pois.",  # ã, and nothing of ours
    "¿Dónde está el baño?",
])
def test_signs_of_another_language_turn_it_away(text):
    assert evidence(text, HERE) is False


def test_cyrillic_is_fine_where_russian_is_expected():
    assert evidence("Почему единицы на подниму?", ["en", "ru"]) is not False


def test_no_signs_either_way_leaves_it_to_the_model():
    assert evidence("Apoi zulas.", HERE) is None
