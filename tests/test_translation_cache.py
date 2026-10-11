from types import SimpleNamespace

import pytest

from translate_core import translate


class Cache:
    def __init__(self, offset=0, trimmable=True):
        self.offset, self.trimmable = offset, trimmable
    def is_trimmable(self):
        return self.trimmable
    def trim(self, n):
        removed = min(n, self.offset)
        self.offset -= removed
        return removed


def translator(monkeypatch, cache):
    obj = translate.LLMTranslator.__new__(translate.LLMTranslator)
    obj.model, obj._cache, obj._cached = object(), [cache], []
    obj.history, obj.context = [], 3
    monkeypatch.setattr(translate, 'make_prompt_cache', lambda model: [Cache()])
    return obj


def test_rotating_cache_is_rebuilt_when_rewind_is_refused(monkeypatch):
    old = Cache(4, trimmable=False)
    obj = translator(monkeypatch, old)
    obj._settle([1, 2, 3, 4])
    assert obj._prepare([1, 2, 9]) == [1, 2, 9]
    assert obj._cache[0] is not old
    assert obj._cache[0].offset == 0


def test_uncached_last_token_is_not_skipped(monkeypatch):
    obj = translator(monkeypatch, Cache(2))
    obj._settle([1, 2, 3])
    assert obj._prepare([1, 2, 3, 4]) == [3, 4]


def test_empty_prompt_is_rejected(monkeypatch):
    obj = translator(monkeypatch, Cache())
    with pytest.raises(ValueError, match='empty'):
        obj._prepare([])


def test_english_only_history_is_bounded(monkeypatch):
    obj = translator(monkeypatch, Cache())
    for i in range(100):
        obj.remember(str(i))
    assert len(obj.history) <= 2 * obj.context
    assert obj.history[-1] == ('99', '99')


def test_closing_incomplete_translation_discards_its_cache(monkeypatch):
    obj = translator(monkeypatch, Cache())
    obj.system, obj.max_tokens = '', 10
    obj.tokenizer = SimpleNamespace(apply_chat_template=lambda *a, **kw: [1, 2])
    def generate(*args, **kwargs):
        obj._cache[0].offset = 3
        yield SimpleNamespace(text='Hello', token=3, finish_reason=None)
    monkeypatch.setattr(translate, 'stream_generate', generate)
    steps = obj.steps('Bonjour')
    next(steps)
    old = obj._cache[0]
    steps.close()
    assert obj._cache[0] is not old
    assert obj._cached == []
    assert obj.history == []
