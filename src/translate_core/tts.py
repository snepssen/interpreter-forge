from pathlib import Path

import numpy as np
from piper import PiperVoice

DEFAULT_VOICE = (
    Path(__file__).resolve().parents[3]
    / "voice-forge/cross-platform/resources/voices/en_US-snepssen-medium.onnx"
)


class PiperTTS:
    """Piper synthesis that also drives voice-forge voices.

    A voice-forge graph takes an extra per-phoneme `vf_duration_factors` input;
    feeding it ones reproduces the stock voice exactly. Stock Piper voices
    render as they always do.
    """

    def __init__(self, path: Path = DEFAULT_VOICE, sentence_gap: float = 0.15):
        if not path.exists():
            raise FileNotFoundError(f"No voice at {path}; pass --voice with a Piper .onnx")
        self.voice = PiperVoice.load(path)
        self.sample_rate = self.voice.config.sample_rate
        self._inputs = {i.name for i in self.voice.session.get_inputs()}
        self.sentence_gap = sentence_gap

    def speak(self, text: str, pace: float = 1.0) -> np.ndarray:
        """`pace` > 1 speaks faster. The graph rounds each phoneme up to a whole
        frame, so it delivers about half of a small request and most of a large
        one: x1.1 asked gives x1.05, x1.4 gives x1.35 on the voice-forge voice."""
        c = self.voice.config
        gap = np.zeros(int(self.sentence_gap / pace * self.sample_rate), np.float32)
        parts: list[np.ndarray] = []
        for phonemes in self.voice.phonemize(text):
            if not phonemes:
                continue
            ids = self.voice.phonemes_to_ids(phonemes)
            args = {
                "input": np.array([ids], np.int64),
                "input_lengths": np.array([len(ids)], np.int64),
                "scales": np.array([c.noise_scale, c.length_scale / pace, c.noise_w_scale], np.float32),
            }
            if "vf_duration_factors" in self._inputs:
                args["vf_duration_factors"] = np.ones((1, 1, len(ids)), np.float32)
            audio = self.voice.session.run(["output"], args)[0].squeeze().astype(np.float32)
            peak = float(np.max(np.abs(audio))) if audio.size else 0.0
            if peak > 1e-8:
                audio *= 0.9 / peak
            if parts:
                parts.append(gap)
            parts.append(audio)
        return np.concatenate(parts) if parts else np.zeros(0, np.float32)
