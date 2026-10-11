import threading
from types import SimpleNamespace

import numpy as np
import pytest

from translate_core import live
from translate_core.types import Segment, Word


class Player:
    def __init__(self, *args):
        self.closed = False
    def backlog(self):
        return 0
    def play(self, clip):
        return 0
    def idle(self):
        return True
    def close(self):
        self.closed = True


class Source:
    stopped = False
    def start(self, push):
        pass
    def done(self):
        return True
    def stop(self):
        self.stopped = True


def interpreter(monkeypatch, speak, on_event=lambda e: None):
    monkeypatch.setattr(live, 'Player', Player)
    monkeypatch.setattr(live, 'SileroVAD', lambda: SimpleNamespace(last_speech=0))
    def steps(*args):
        yield
        return 'Hello.'
    obj = live.LiveInterpreter(None, SimpleNamespace(steps=steps),
                               SimpleNamespace(sample_rate=16000, speak=speak), on_event=on_event)
    piece = Segment(0, [Word('Bonjour.', 0, 1)], 'flush', 1)
    monkeypatch.setattr(obj, '_pass', lambda *a, **kw: [piece])
    return obj


def run_bounded(obj, source):
    result = []
    def run():
        try:
            result.append(obj._run(source, False, threading.Event()))
        except Exception as error:
            result.append(error)
    worker = threading.Thread(target=run, daemon=True)
    worker.start()
    worker.join(timeout=3)
    assert not worker.is_alive(), 'CLI hung after a synthesis/notification error'
    assert source.stopped
    return result[0]


@pytest.mark.parametrize('stage', ['synthesis', 'notification'])
def test_worker_errors_reach_caller_and_cleanup(monkeypatch, stage):
    failure = RuntimeError(f'{stage} failed')
    def fail(*a, **kw):
        raise failure
    speak = fail if stage == 'synthesis' else lambda *a, **kw: np.zeros(160, np.float32)
    on_event = fail if stage == 'notification' else lambda e: None
    obj = interpreter(monkeypatch, speak, on_event)
    assert run_bounded(obj, Source()) is failure


def test_success_finishes_and_closes_player(monkeypatch):
    obj = interpreter(monkeypatch, lambda *a, **kw: np.zeros(160, np.float32))
    player = run_bounded(obj, Source())
    assert isinstance(player, Player)
    assert player.closed
    assert len(obj.events) == 1


def test_source_start_failure_cleans_up(monkeypatch):
    obj = interpreter(monkeypatch, lambda *a, **kw: np.zeros(160, np.float32))
    failure = RuntimeError('no microphone')
    class BrokenSource(Source):
        def start(self, push):
            raise failure
    assert run_bounded(obj, BrokenSource()) is failure


def test_silent_pass_advances_window_without_running_asr(monkeypatch):
    obj = interpreter(monkeypatch, lambda *a, **kw: np.zeros(160, np.float32))
    # Use the actual pass rather than the recording fixture's stub.
    segmenter = live.Segmenter()
    live.LiveInterpreter._pass(obj, segmenter, SimpleNamespace(last_speech=-1), np.zeros(0), 0, 100)
    assert segmenter.window_start() >= 99


def test_microphone_cleanup_is_safe_before_start():
    live.Microphone().stop()
