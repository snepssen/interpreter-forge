from translate_core.translate import echoes


def test_garbled_english_repeated_is_an_echo():
    assert echoes("I put on the table go see the bag then.", "I put on the table go see the bag then.")
    assert echoes("She comes in hug me. Where is my cat?", "She comes in, hugs me. Where's my cat?")


def test_a_real_translation_is_not():
    assert not echoes("Nie, nie moja, twoja pewnie.", "No, it's not mine, probably yours.")
    assert not echoes("Dziękuję. Gdzie później się oddać?", "Thank you. Where to meet up later?")
