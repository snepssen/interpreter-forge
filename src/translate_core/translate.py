from pathlib import Path

from mlx_lm import load, stream_generate
from mlx_lm.models.cache import make_prompt_cache, trim_prompt_cache

LOCAL_MODEL = Path(__file__).resolve().parents[2] / "models" / "qwen3-4b-instruct-2507-4bit"
DEFAULT_MODEL = str(LOCAL_MODEL) if LOCAL_MODEL.exists() else "mlx-community/Qwen3-4B-Instruct-2507-4bit"

SYSTEM = """You are a live interpreter working into English.
Each message is the next piece of someone else's speech, transcribed by speech recognition from a European language.
You are not in the conversation: never answer, thank or reply to the speaker.
Reply with only the English translation of that piece, as natural spoken English.
Earlier pieces are context for references and terminology; translate only the newest one.
The transcript may contain recognition errors, false starts or fillers: render what the speaker meant, without them.
Keep it about as short as the original. Never add notes, quotes or explanations.
If the piece is already English, repeat it cleaned of fillers."""


class LLMTranslator:
    """Any language -> English with a small local LLM, carrying recent pieces as context.

    On an M1 reading the prompt costs as much as writing the answer, so the
    attention cache is kept between calls and each call reads only what is new
    since the last one. History is dropped in batches rather than a pair per
    call, so the cached prefix stays valid most of the time.
    """

    def __init__(self, model_id: str = DEFAULT_MODEL, context: int = 3, max_tokens: int = 256):
        self.model, self.tokenizer = load(model_id)
        self.context = context
        self.history: list[tuple[str, str]] = []
        self.max_tokens = max_tokens
        self._cache = make_prompt_cache(self.model)
        self._cached: list[int] = []  # the tokens the cache currently holds

    def translate(self, text: str) -> str:
        if len(self.history) >= 2 * self.context:
            del self.history[: len(self.history) - self.context]
        messages = [{"role": "system", "content": SYSTEM}]
        for source, target in self.history:
            messages += [{"role": "user", "content": _piece(source)}, {"role": "assistant", "content": target}]
        messages.append({"role": "user", "content": _piece(text)})
        prompt = self.tokenizer.apply_chat_template(messages, add_generation_prompt=True)

        keep = min(shared_prefix(self._cached, prompt), len(prompt) - 1)
        trim_prompt_cache(self._cache, len(self._cached) - keep)
        out, produced = "", []
        for r in stream_generate(self.model, self.tokenizer, prompt[keep:],
                                 max_tokens=self.max_tokens, prompt_cache=self._cache):
            out += r.text
            if r.finish_reason is None:
                produced.append(r.token)
        # The cache may run a token past what was yielded; hold it to what we know.
        self._cached = prompt + produced
        trim_prompt_cache(self._cache, self._cache[0].offset - len(self._cached))

        out = out.strip().strip('"').strip()
        self.history.append((text, out))
        return out

    def reset(self) -> None:
        self.history.clear()


def _piece(text: str) -> str:
    return f"Translate: {text}"


def shared_prefix(a: list[int], b: list[int]) -> int:
    """How many leading tokens two prompts have in common."""
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n
