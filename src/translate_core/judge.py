"""Yes/no questions to the LLM about a piece of transcribed speech.

One forward pass, no generation: the answer is whichever of "yes" and "no" the
model finds likelier as its first word. Each question's instructions are the
same every time, so their attention cache is kept and a call only pays for its
own few tokens; and only the last position goes through the output layer,
rather than the whole prompt times the vocabulary.
"""

import re

import mlx.core as mx
from mlx_lm.models.cache import make_prompt_cache, trim_prompt_cache

from .translate import shared_prefix

COMPLETE = """You decide when a simultaneous interpreter may start translating.
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

ENGLISH = """You check transcribed speech for a live interpreter who translates into English.
Answer yes if the text is English, so the listener needs no translation. A borrowed foreign word or name inside English is still English.
Answer no if the text is mainly in another language, even if it contains some English words.

Examples:
"Thank you so much, that was lovely." → yes
"It's very popular in Poland, like pierogi." → yes
"Dziękuję bardzo, to było pyszne." → no
"Nem tudom, mikor jön a busz." → no
"Ja, dat klopt, maar het is te laat." → no
"To jest bardzo popular teraz, wiesz, like everywhere." → no

Answer with one word: yes or no."""


class YesNo:
    def __init__(self, model, tokenizer, instructions: str, strip_final_mark: bool = False):
        self.model, self.tokenizer = model, tokenizer
        self.instructions = instructions
        self.strip_final_mark = strip_final_mark
        self._yes = _token_ids(tokenizer, ("yes", "Yes", " yes", " Yes"))
        self._no = _token_ids(tokenizer, ("no", "No", " no", " No"))
        self._cache = make_prompt_cache(model)
        self._cached: list[int] = []  # the tokens the cache currently holds

    def __call__(self, text: str) -> bool:
        text = text.strip()
        if self.strip_final_mark:
            text = re.sub(r"[.?!…]+$", "", text)
        messages = [{"role": "system", "content": self.instructions}, {"role": "user", "content": f'"{text}"'}]
        prompt = self.tokenizer.apply_chat_template(messages, add_generation_prompt=True)

        keep = min(shared_prefix(self._cached, prompt), len(prompt) - 1)
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


def CompletenessJudge(model, tokenizer) -> YesNo:
    """Can this be translated correctly now? Parakeet ends every window with a
    full stop, which says nothing about meaning, so that is stripped first."""
    return YesNo(model, tokenizer, COMPLETE, strip_final_mark=True)


class EnglishCheck:
    """Is this already English, so the listener needs no interpreter?

    Letters English doesn't use (ą, ł, ż, ő, ű, ë...) settle it without asking:
    mixed speech that has them is mostly the other language, and a missed
    translation costs more than a needless one. A single one is let through,
    for the odd café or naïve.
    """

    def __init__(self, model, tokenizer):
        self._ask = YesNo(model, tokenizer, ENGLISH)

    def __call__(self, text: str) -> bool:
        foreign = sum(ch.isalpha() and not ch.isascii() for ch in text)
        return foreign < 2 and self._ask(text)


def _token_ids(tokenizer, words: tuple[str, ...]) -> mx.array:
    """First token of each spelling; the model's answer starts with one of them."""
    return mx.array(sorted({tokenizer.encode(w, add_special_tokens=False)[0] for w in words}))
