import mlx.core as mx
import numpy as np
from huggingface_hub import snapshot_download
from parakeet_mlx import from_pretrained
from parakeet_mlx.audio import get_logmel

from .types import Word

DEFAULT_MODEL = "mlx-community/parakeet-tdt-0.6b-v3"


class ParakeetASR:
    def __init__(self, model_id: str = DEFAULT_MODEL):
        self.model = from_pretrained(_local(model_id))
        self.sample_rate = self.model.preprocessor_config.sample_rate

    def transcribe(self, audio: np.ndarray, offset: float = 0.0) -> list[Word]:
        """Words in `audio`, timed in stream seconds (`offset` = where it starts)."""
        if len(audio) < self.model.preprocessor_config.hop_length * 4:
            return []
        mel = get_logmel(mx.array(audio, dtype=mx.float32), self.model.preprocessor_config)
        result = self.model.generate(mel)[0]
        return _words(result.tokens, offset)


def _words(tokens, offset: float) -> list[Word]:
    """Join subword tokens into words; a leading space starts a new word.

    Punctuation tokens are often stamped well into the silence after a word,
    so they add to the text but not to the word's end time.
    """
    words: list[Word] = []
    text, start, end = "", 0.0, 0.0
    for token in tokens:
        if token.text.startswith(" ") and text.strip():
            words.append(Word(text.strip(), offset + start, offset + end))
            text = ""
        if not text.strip():
            start = end = token.start
        text += token.text
        if any(c.isalnum() for c in token.text):
            end = token.end
    if text.strip():
        words.append(Word(text.strip(), offset + start, offset + end))
    return words


def _local(model_id: str) -> str:
    """The cached copy if there is one: asking the hub first can stall a launch
    for a minute on a poor connection, just to learn nothing has changed."""
    try:
        return snapshot_download(model_id, local_files_only=True)
    except Exception:
        return model_id
