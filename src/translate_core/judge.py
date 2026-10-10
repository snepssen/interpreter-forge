"""Yes/no questions to the LLM about a piece of transcribed speech.

One forward pass, no generation: the answer is whichever of "yes" and "no" the
model finds likelier as its first word. Each question's instructions are the
same every time, so their attention cache is kept and a call only pays for its
own few tokens; and only the last position goes through the output layer,
rather than the whole prompt times the vocabulary.
"""

import re
import unicodedata

import mlx.core as mx
from mlx_lm.models.cache import make_prompt_cache, trim_prompt_cache

from .languages import LETTERS, SCRIPTS, WORDS, names
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
        return self.probability(text) >= 0.5

    def probability(self, text: str) -> float:
        """How sure the model is that the answer is yes, between yes and no."""
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
        return float(mx.sigmoid(yes - no).item())

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


EXPECTED = """You check transcribed speech for a live interpreter. The people speaking use {names}.
Speech recognition sometimes writes their speech down in the wrong language: Polish heard as Russian, Spanish or Romanian, for example.
Answer yes if the text is in {names}; a few words of another language mixed in is fine.
Answer no if it is mainly in some other language.

Answer with one word: yes or no."""


class Gate:
    """Before translating: does this piece need it?

    Returns "" to translate it, "english" if it is already English (the
    listener understands it), or "language" if it isn't in any language
    expected here, which means the speech recognition went astray.

    Dropping real speech is the worse mistake, so the evidence that a piece
    is in an expected language is looked at before the model is asked: the
    model is sure garbled Hungarian is not Hungarian.
    """

    def __init__(self, model, tokenizer, english: bool = True, languages: list[str] | None = None):
        self._english = EnglishCheck(model, tokenizer) if english else None
        self.skips_english = english  # then a translation that just repeats its source is noise too
        self.languages = languages or []
        self._expected = YesNo(model, tokenizer, EXPECTED.format(names=names(languages))) if languages else None

    def __call__(self, text: str) -> str:
        if self._english and self._english(text):
            return "english"
        if self._expected and not self._expected_language(text):
            return "language"
        return ""

    def _expected_language(self, text: str) -> bool:
        verdict = evidence(text, self.languages)
        return self._expected(text) if verdict is None else verdict


def evidence(text: str, languages: list[str]) -> bool | None:
    """What the text itself says about being in one of `languages`: True, False,
    or None when it doesn't say and the model has to be asked."""
    scripts = {SCRIPTS.get(c, "LATIN") for c in languages}
    letters = [ch for ch in text.lower() if ch.isalpha()]
    if sum(unicodedata.name(ch, "").split(" ")[0] not in scripts for ch in letters) >= 2:
        return False  # Cyrillic for Polish, say
    words = set(re.findall(r"\w+", text.lower()))
    if any(set(LETTERS.get(c, "")) & set(letters) or WORDS.get(c, set()) & words for c in languages):
        return True
    if any(set(LETTERS[c]) & set(letters) for c in LETTERS if c not in languages):
        return False  # ã, ñ, ß... and nothing of ours
    return None
