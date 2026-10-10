from collections import deque

from mlx_lm import generate, load

DEFAULT_MODEL = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

SYSTEM = """You are a live interpreter working into English.
Each message is the next piece of a speech, transcribed by speech recognition from a European language.
Reply with only the English translation of that piece, as natural spoken English.
Earlier pieces are context for references and terminology; translate only the newest one.
The transcript may contain recognition errors, false starts or fillers: render what the speaker meant, without them.
Keep it about as short as the original. Never add notes, quotes or explanations.
If the piece is already English, repeat it cleaned of fillers."""


class LLMTranslator:
    """Any language -> English with a small local LLM, carrying recent pieces as context."""

    def __init__(self, model_id: str = DEFAULT_MODEL, context: int = 3, max_tokens: int = 256):
        self.model, self.tokenizer = load(model_id)
        self.history: deque[tuple[str, str]] = deque(maxlen=context)
        self.max_tokens = max_tokens

    def translate(self, text: str) -> str:
        messages = [{"role": "system", "content": SYSTEM}]
        for source, target in self.history:
            messages += [{"role": "user", "content": source}, {"role": "assistant", "content": target}]
        messages.append({"role": "user", "content": text})
        prompt = self.tokenizer.apply_chat_template(messages, add_generation_prompt=True)
        out = generate(self.model, self.tokenizer, prompt=prompt, max_tokens=self.max_tokens, verbose=False)
        out = out.strip().strip('"').strip()
        self.history.append((text, out))
        return out
