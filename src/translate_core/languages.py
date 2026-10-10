"""The languages Parakeet v3 transcribes."""

LANGUAGES = {
    "bg": "Bulgarian", "cs": "Czech", "da": "Danish", "de": "German", "el": "Greek", "en": "English",
    "es": "Spanish", "et": "Estonian", "fi": "Finnish", "fr": "French", "hr": "Croatian", "hu": "Hungarian",
    "it": "Italian", "lt": "Lithuanian", "lv": "Latvian", "mt": "Maltese", "nl": "Dutch", "pl": "Polish",
    "pt": "Portuguese", "ro": "Romanian", "ru": "Russian", "sk": "Slovak", "sl": "Slovenian", "sv": "Swedish",
    "uk": "Ukrainian",
}
SCRIPTS = {"bg": "CYRILLIC", "ru": "CYRILLIC", "uk": "CYRILLIC", "el": "GREEK"}  # all others: LATIN


def names(codes: list[str]) -> str:
    """"Polish, Hungarian and Dutch" for ["pl", "hu", "nl"]."""
    words = [LANGUAGES[c] for c in codes]
    return words[0] if len(words) == 1 else ", ".join(words[:-1]) + " and " + words[-1]

# Letters that all but give a language away. Only distinctive ones: á, é, ö...
# are shared too widely to mean anything.
LETTERS = {
    "pl": "łąęśźć", "hu": "őű", "cs": "řěů", "sk": "ľĺŕ", "ro": "ășț", "es": "ñ¿¡",
    "pt": "ãõ", "de": "ß", "fr": "œ", "da": "æø", "lt": "ėįųū", "lv": "āēīūļņķģ", "mt": "ħġ",
}

# Everyday words of a language that English (and its neighbours here) doesn't
# share: "nem", "tudom" mark Hungarian even when the rest came out garbled.
# For the languages this has been used with; others fall back to asking the model.
WORDS = {
    "pl": {"nie", "tak", "jest", "że", "się", "ale", "czy", "już", "jak", "tylko", "mnie", "wiesz",
           "dobra", "dobrze", "teraz", "jestem", "jesteś", "mówię", "może", "tego", "tym", "był", "była"},
    "hu": {"nem", "igen", "hogy", "egy", "meg", "csak", "van", "nincs", "tudom", "azt", "és", "már",
           "akkor", "persze", "nagyon", "szia", "mert", "vagy", "volt", "lesz", "itt", "ott", "nekem"},
    "nl": {"ik", "het", "een", "niet", "dat", "wat", "maar", "ook", "nog", "toch", "zijn", "heb",
           "hebt", "jij", "wij", "geen", "veel", "gezellig", "lekker", "kijk", "zeg"},
}
