import urllib.request
from pathlib import Path

import numpy as np
import onnxruntime as ort

from .audio import SAMPLE_RATE

SILERO_URL = "https://raw.githubusercontent.com/snakers4/silero-vad/master/src/silero_vad/data/silero_vad.onnx"
DEFAULT_PATH = Path(__file__).resolve().parents[2] / "models" / "silero_vad.onnx"


class SileroVAD:
    """Silero VAD v5, fed 32 ms frames, with hysteresis on its speech probability."""

    FRAME = 512  # samples at 16 kHz
    CONTEXT = 64  # samples of the previous frame the v5 graph expects in front

    def __init__(self, path: Path = DEFAULT_PATH, on: float = 0.5, off: float = 0.35):
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            urllib.request.urlretrieve(SILERO_URL, path)
        options = ort.SessionOptions()
        options.inter_op_num_threads = options.intra_op_num_threads = 1
        self._session = ort.InferenceSession(str(path), options, providers=["CPUExecutionProvider"])
        self.on, self.off = on, off
        self.reset()

    def reset(self) -> None:
        self._state = np.zeros((2, 1, 128), np.float32)
        self._context = np.zeros((1, self.CONTEXT), np.float32)
        self.speaking = False
        self.last_speech = -1e9  # stream time of the last frame heard as speech

    def push(self, frame: np.ndarray, t: float) -> bool:
        """Feed one frame ending at stream time `t`; returns whether it is speech."""
        x = np.concatenate([self._context, frame[None, :].astype(np.float32)], axis=1)
        out, self._state = self._session.run(
            None, {"input": x, "state": self._state, "sr": np.array(SAMPLE_RATE, np.int64)}
        )
        self._context = x[:, -self.CONTEXT:]
        p = float(out[0][0])
        self.speaking = p >= self.on or (self.speaking and p >= self.off)
        if self.speaking:
            self.last_speech = t
        return self.speaking

    def silence(self, now: float) -> float:
        return 0.0 if self.speaking else max(0.0, now - self.last_speech)
