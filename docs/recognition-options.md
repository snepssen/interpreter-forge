# Local recognition options

The native Mac and iPhone apps offer two recognition models, independently of
the translation model. Choose one in **Models → Speech recognition**, while
stopped. The app remembers the choice and releases the old recognizer before
loading another. Downloads and recognition stay separate from translation:
speech is transcribed in its original language, then passed to the existing
translation and voice pipeline.

| Model | Recognition languages | Approximate download | Runtime |
| --- | --- | --- | --- |
| Parakeet Ultra (default) | 25 European languages | 630 MB | FluidAudio, Neural Engine |
| Whisper large-v3 Turbo | 100 | 626 MB plus tokenizer | WhisperKit, Core ML |

The exact Whisper variant is `large-v3-v20240930_626MB`, which Argmax currently
[recommends for iOS and macOS](https://github.com/argmaxinc/argmax-oss-swift#model-selection).
WhisperKit is pinned to the open-source SDK's 1.1.1 release. Its implementation
continues to change independently of the older model weights. Argmax's
[September 2026 Pro SDK](https://www.argmaxinc.com/blog/argmax-sdk-3) adds Qwen3-ASR;
that commercial SDK is not a dependency of this app.

Ultra is a post-trained v3 model with the same word-timing contract. FluidAudio
[reports better accuracy at similar speed](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md).
Those benchmark results do not establish accuracy for the user's Dutch,
Romanian and Hungarian conversations.

## Languages

The language menu follows the chosen recognizer's supported set. Switching
from Whisper to Ultra removes unsupported languages from the filter and shows
a notice; English remains included. The menu restricts which languages get
translated, and is **not** a forced recognition-language setting. Whisper uses
audio language detection on each window; Parakeet uses its own multilingual
decoder with a script hint when appropriate.

Broader recognition does not establish broader translation coverage:
TranslateGemma supports 55 languages. The text language detector and prompt
labels now include Whisper's language codes; the European-specific text
heuristics are bypassed for filters containing other languages/scripts.

## Cache and lifecycle

Ultra uses its own FluidAudio cache. The previous v3 weights are retained,
but cannot be reused as Ultra weights. The first Ultra launch needs a download.

Whisper files and tokenizer live in the app's Application Support storage,
excluded from backups. A completion manifest records relative paths and file
sizes only after both models and tokenizer load successfully. Missing or
truncated files invalidate it. A valid cache skips the model downloader;
downloads cancelled before loading cannot create a completion record.

Switching is disabled during a live session or preparation. Load failures show
the existing retry state, without silently switching to another recognizer.
Whisper uses one decoding worker, word timestamps and bounded audio windows.
Its timestamps are offset into the session timeline and clipped to the input
window. Existing cancellation, background and audio-route handling still apply.

For a recording through the full native pipeline:

```sh
apple/.build/xcode/Build/Products/Release/tcrun recording.wav \
  --recognition whisper-large-v3-v20240930-626mb
# or --recognition parakeet-ultra
```

Keep recordings and transcripts local. Compare accuracy, wrong-language
guesses, delay and memory on the same recordings, including switches between
speakers and short replies, before judging a model for a conversation.

## Verification, 11 October 2026

The native engine suite passed 28 tests; the optional real-model test is skipped
in ordinary runs. The core checker passed all 53 checks. Separate opt-in runs
loaded both real recognizers and transcribed the same ten-second recording.
On an M1 Mac, recognition took about 0.19 seconds with Ultra and 2.42 seconds
with Whisper. A second Whisper run verified a complete cache, no model-download
progress and successful recognition (about 1.78 seconds). Initial download and
Core ML preparation took several minutes for each model.

A separate thirty-second recording ran through Whisper, TranslateGemma and
voice synthesis: two pieces were translated and spoken, and an English piece
was left quiet. These are functional smoke checks, not language-accuracy or
representative latency benchmarks.

Both release apps rebuilt and passed strict code-signature verification. The
updated app was installed on the iPhone, and the user confirmed that Ultra and
Whisper both reach working recognition. On the Mac, the model manager switched
to Whisper, reached Ready, started Live and returned to Ready when stopped.
Recordings, transcripts, model downloads and built apps remain local.
