import pytest

from cases import load
from translate_core.judge import evidence

CASES = load("language-evidence")["cases"]


@pytest.mark.parametrize("case", CASES, ids=[c["text"] for c in CASES])
def test_language_evidence(case):
    got = evidence(case["text"], case["expected"])
    if case["evidence"] == "notFalse":
        assert got is not False
    else:
        assert got is case["evidence"]
