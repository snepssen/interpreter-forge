"""The shared cases in `cases/`, which tccheck and ParityTest.kt answer too."""
import json
import re
from pathlib import Path

from translate_core.types import Word

CASES = Path(__file__).resolve().parents[1] / "cases"


def load(name: str):
    return json.loads((CASES / f"{name}.json").read_text(encoding="utf-8"))


def snake(name: str) -> str:
    """The cases spell config fields as Swift and Kotlin do."""
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def words(groups) -> list[Word]:
    """One word every `step` seconds from `start`, each lasting 0.3 s, per group."""
    out = []
    for g in groups:
        start, step = g.get("start", 0.0), g.get("step", 0.4)
        out += [Word(t, start + i * step, start + i * step + 0.3) for i, t in enumerate(g["text"].split())]
    return out
