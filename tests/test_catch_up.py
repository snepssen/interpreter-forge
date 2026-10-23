import pytest

from cases import load
from translate_core.pipeline import Backlog

CASES = load("catch-up")


@pytest.mark.parametrize("backlog, brief", CASES["brief"])
def test_brief_past_the_backlog_limit(backlog, brief):
    assert Backlog().brief(backlog) is brief


@pytest.mark.parametrize("backlog, pace", CASES["pace"])
def test_pace_rises_with_the_backlog_up_to_its_ceiling(backlog, pace):
    assert Backlog().pace(backlog) == pytest.approx(pace)
