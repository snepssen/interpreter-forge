"""Asks the LLM whether a stretch of speech can be translated yet.

One forward pass, no generation: the answer is whichever of "yes" and "no" the
model finds likelier as its first word. The trailing mark is stripped first,
since Parakeet ends every window with one and it says nothing about meaning.

The instructions are the same every time, so their attention cache is kept and
each question only pays for its own few tokens; and only the last position goes
through the output layer, rather than the whole prompt times the vocabulary.
"""

import re

import mlx.core as mx
from mlx_lm.models.cache import make_prompt_cache, trim_prompt_cache

SYSTEM = """You decide when a simultaneous interpreter may start translating.
You see the beginning of what someone is saying in a European language, from speech recognition.
Answer yes if it is a complete thought that can be translated correctly now, even if more may follow.
Answer no if its meaning depends on words still to come: a German or Dutch clause still waiting for its verb, a sentence stopping after a preposition, article or conjunction, an unfinished comparison or list.

Examples:
"dass wir morgen nicht um neun" → no
"Der Zug fällt wegen Bauarbeiten aus" → yes
"Wir haben das Problem gestern" → no
"Je pense que le projet avance bien" → yes
"Il treno parte alle" → no
"Si tenéis preguntas, podéis escribirme" → yes

Answer with one word: yes or no."""


class CompletenessJudge:
    def __init__(self, model, tokenizer):
        self.model, self.tokenizer = model, tokenizer
        self._yes = _token_ids(tokenizer, ("yes", "Yes", " yes", " Yes"))
        self._no = _token_ids(tokenizer, ("no", "No", " no", " No"))
        self._cache = make_prompt_cache(model)
        self._cached: list[int] = []  # the tokens the cache currently holds

    def __call__(self, text: str) -> bool:
        text = re.sub(r"[.?!…]+$", "", text.strip())
        messages = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": f'"{text}"'}]
        prompt = self.tokenizer.apply_chat_template(messages, add_generation_prompt=True)

        keep = min(_shared(self._cached, prompt), len(prompt) - 1)
        trim_prompt_cache(self._cache, len(self._cached) - keep)
        hidden = self.model.model(mx.array([prompt[keep:]]), self._cache)[:, -1:]
        self._cached = prompt
        logits = self._head(hidden)[0, -1]

        yes, no = mx.max(logits[self._yes]), mx.max(logits[self._no])
        return bool((yes > no).item())

    def _head(self, hidden: mx.array) -> mx.array:
        if getattr(self.model.args, "tie_word_embeddings", False):
            return self.model.model.embed_tokens.as_linear(hidden)
        return self.model.lm_head(hidden)


def _shared(a: list[int], b: list[int]) -> int:
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n


def _token_ids(tokenizer, words: tuple[str, ...]) -> mx.array:
    """First token of each spelling; the model's answer starts with one of them."""
    return mx.array(sorted({tokenizer.encode(w, add_special_tokens=False)[0] for w in words}))
