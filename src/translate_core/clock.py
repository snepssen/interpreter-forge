"""Clock times that count toward the next hour, rewritten as digits before translation.

German and Dutch "halb elf" / "half elf" is 10:30, not 11:30, and "drei viertel
acht" is 7:45. A 4B model reads these the English way every time, prompt or
no prompt, and a wrong meeting time is the worst kind of wrong. So they are
made unambiguous before the model sees them: "um halb elf" → "um 10:30".
Forms that count from the hour ("Viertel nach vier") are left alone; the model
gets those right.
"""

import re

HOURS = {
    # German
    "eins": 1, "zwei": 2, "drei": 3, "vier": 4, "fünf": 5, "sechs": 6, "sieben": 7,
    "acht": 8, "neun": 9, "zehn": 10, "elf": 11, "zwölf": 12,
    # Dutch
    "een": 1, "één": 1, "twee": 2, "vijf": 5, "zes": 6, "zeven": 7, "negen": 9, "tien": 10, "twaalf": 12,
}
_HOUR = r"(\d{1,2}|" + "|".join(sorted(HOURS, key=len, reverse=True)) + r")"

# (pattern, minutes past the hour before), all counting toward the named hour.
_RULES = [
    (r"\b(?:halb|half)\s+" + _HOUR + r"\b", 30),
    (r"\b(?:drei\s*viertel|dreiviertel)\s+" + _HOUR + r"\b", 45),
    (r"\b(?:viertel|kwart)\s+(?:vor|voor)\s+" + _HOUR + r"\b", 45),
]


def _hour(word: str) -> int | None:
    n = int(word) if word.isdigit() else HOURS.get(word.lower())
    return n if n is not None and 1 <= n <= 24 else None


def normalise(text: str) -> str:
    for pattern, minutes in _RULES:
        def digits(m: re.Match) -> str:
            n = _hour(m.group(1))
            if n is None:
                return m.group(0)
            return f"{n - 1 if n > 1 else 12}:{minutes:02d}"
        text = re.sub(pattern, digits, text, flags=re.IGNORECASE)
    return text
