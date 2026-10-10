# translate-core

Live speech interpretation that works like a human interpreter rather than a
walkie-talkie. It listens continuously, waits until a thought is complete, and
passes it on to be translated and spoken in your ear while it keeps listening.
Everything runs locally.

    mic ─▶ VAD ─▶ segmenter ─▶ translate ─▶ speak ─▶ headphones
                  ▲      │
                  └ ASR ◀┘  re-reads the uncommitted tail every 0.5 s

First target: **any European language → English**, on an Apple Silicon Mac.

| stage     | model                                        |
|-----------|----------------------------------------------|
| VAD       | Silero VAD v5 (ONNX)                         |
| ASR       | Parakeet TDT 0.6B v3 via `parakeet-mlx` — 25 European languages, punctuated |
| translate | Qwen3-4B-Instruct-2507, 4-bit MLX, carrying the last three pieces as context |
| speak     | Piper; defaults to the voice-forge voice next door in `../voice-forge` |

## Deciding when a thought is complete

This is the part the rest hangs on. The ASR re-reads everything after the last
commit mark every hop, and the segmenter commits only words that came out the
same on two passes in a row, and only at a safe place:

- **sentence**: a sentence-final mark with recognised speech after it.
- **judged**: a short pause (0.4 s) after stable speech, and the judge says
  it can be translated on its own.
- **pause**: silence long enough that what was said is all there is
  (1.4 s, stretched to fit a speaker who hesitates a lot).
- **clause**: 6 s without a sentence end; cut at the latest comma the judge
  accepts.
- **force**: 10 s; cut where the judge accepts, else wait, up to 15 s, then
  cut at the widest gap.

The judge is the translation LLM asked one yes/no question: *can this be
translated correctly now, or does its meaning hang on words still to come?*
It's one forward pass with the instructions' attention cache kept between
calls, about 0.2 s on an M1, and it got 17 of 18 held-out phrases right in
six languages. It's what stops `dass wir morgen nicht um 9,` going out at a
comma before its verb, `anfangen`, arrives. `--no-judge` turns it off for
comparison.

The first rule is narrower than it looks, for a measured reason. Parakeet puts
a full stop at the end of any window it's given, and a mid-clause hesitation is
enough to earn one: *"…dass wir."* with the verb still to come. Trusting that
mark after a pause shipped the clause without its verb. Once the speaker
carries on, the re-read across the pause drops the false stop by itself
(*"…dass wir morgen … um halb elf anfangen."*). So a mark only counts when
there is speech on its far side.

## Running it

    uv sync
    scripts/fetch-models.sh                       # the translation model, into models/
    scripts/make-samples.sh                       # synthetic test speech, macOS `say`
    uv run translate-core samples/de_halting.wav  # → runs/de_halting/
    uv run pytest

Each run writes `listen.wav` (left: the speaker, right: the interpreter, placed
when it would really play), `trace.jsonl` (every segment with its words and
stage times) and `summary.txt`. `--segment-only` stops after segmentation;
`--mt` takes a Hugging Face id or a local model directory.

The harness decides exactly as it would live (the segmenter only ever sees
audio up to *now*), measures each stage's compute for real, and lays it onto a
clock where each stage is one worker, so queueing shows up as lag. Live, ASR
and translation share the GPU, so treat these latencies as a lower bound.

## Not yet

- Live microphone → headphones.
- Backlog control: condense the translation, then tighten the voice-forge
  timing, when the interpreter falls behind.
- Any → any.
