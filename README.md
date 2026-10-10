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
- **clause**: 4 s without a sentence end; cut at the latest comma the judge
  accepts.
- **force**: 5 s; cut where the judge accepts, else wait, up to 6 s, then
  cut at the widest gap. Each piece is translated with the ones before it as
  context, so a thought split at 5 s still reads on.

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
    uv run translate-core file samples/de_halting.wav       # simulated clock → runs/de_halting/
    uv run translate-core file recordings/*.m4a              # several at once, with a comparison table
    uv run translate-core live --from samples/de_halting.wav  # real time → runs/live-de_halting/
    uv run translate-core live                               # your mic → your headphones
    uv run translate-core devices                            # which mics and outputs there are
    uv run pytest

Each run writes `listen.wav` (left: the speaker, right: the interpreter, placed
when it would really play), `trace.jsonl` (every segment with its words and
stage times) and `summary.txt`. `--segment-only` stops after segmentation;
`--mt` takes a Hugging Face id or a local model directory.

The harness decides exactly as it would live (the segmenter only ever sees
audio up to *now*), measures each stage's compute for real, and lays it onto a
clock where each stage is one worker, so queueing shows up as lag. Live, ASR
and translation share the GPU, so treat these latencies as a lower bound.

## Live

`translate-core live` listens to the microphone and speaks into the default
output; plug headphones in first, or the mic will hear the interpreter. The
first Ctrl-C stops listening and finishes what was already heard; a second
abandons it. Every session leaves a listen-back and trace in `runs/`.
`--from` feeds a recording in at real-time pace instead, which is how the
numbers below were measured: the same loop, with ASR and translation really
competing for the GPU.

MLX runs on one thread and translation goes first. A committed piece waiting
is lag the listener hears; a delayed ASR pass only delays the next commit,
whose translation would queue behind this one anyway. Median lag, real time,
M1 (one run each; repeated runs vary by about ±0.3 s):

| sample | time-sliced | translation first |
|---|---|---|
| Spanish, fluent | 5.2 s | 3.2 s |
| Italian, self-correcting | 3.8 s | 3.1 s |
| German, hesitant | 4.4 s | 3.7 s |
| French, one run-on sentence | 8.4 s | 6.7 s |

## Falling behind

The English can take longer to say than the original, and a speaker who never
stops gives no room to catch up. So, like a human interpreter, it says less and
says it faster once English is queueing: past 1.5 s of backlog the next piece is
translated for the gist, and past 1 s the voice speeds up, to at most 1.3x.
The voice graph rounds each phoneme up to a whole frame, so a request for 1.1x
delivers about 1.05x and 1.4x about 1.35x. On the French run-on this brings the
interpreter's speech from 19.1 s down to 16.1 s against 15.5 s of source, and the
worst lag from 14.9 s to 12.4 s; what remains is the 11 s before the first piece
could be cut at all. `--no-catch-up` turns it off.

## English is left alone

You understand English, and in a conversation the English side is usually you
or someone talking to you. So before translating, the model is asked one more
yes/no question, *is this already English?*, in the same single pass as the
judge. Two or more letters English doesn't use (ą, ł, ż, ő, ű...) answer it
without asking. English pieces aren't spoken; they're kept as conversation
context, so replies to them translate better. 17 of 18 right on real and
held-out phrases; the miss was English heard as foreign, which only costs a
needless repeat. `--speak-english` voices everything.

## Real conversation

A 70-minute recording of English, Polish, Hungarian and some Dutch, mostly
two or three people talking over each other, behaved nothing like the
synthetic samples. What it changed, measured on an 8-minute stretch of fast
Polish and Hungarian (58–66 min):

| | before | after |
|---|---|---|
| commit wait, median / p90 | 5.3 / 12.8 s | 2.5 / 3.7 s |
| lag of spoken pieces, median / max | 10.9 / 18.1 s | 5.0 / 10.8 s |
| forced cuts | 17 | 0 |

Over the whole 70 minutes, the same changes took the median lag of spoken
pieces from 7.8 to 3.9 s (p90 14.1 → 7.1 s, worst 24.9 → 12.8 s) and forced
cuts from 75 to 11; ASR passes got twice as fast (0.77 → 0.39 s) because
quicker commits keep the windows short. 916 of 1,022 pieces were English and
stayed quiet.

- **Agreement is aligned word by word**, not a common prefix. In a long
  window of conversation some early word nearly always flickers, and a prefix
  rule held back everything after it. Now a prefix is stable when its last
  word and 80% of its words agree with the last pass.
- **A pause is also measured from the last word transcribed.** The VAD went
  on hearing "speech" (noise, a faint voice) for half a minute after a
  two-word "Nem tudom", and nothing got cut.
- **Garbled English isn't spoken back.** Accented English the ASR mangles
  fails the English check, and the model then repeats it; 40 of 101
  "translations" in the full recording were that. A translation that is
  mostly its source again (≥ 0.6 word similarity) now stays quiet. No real
  translation came near that.
- **Waiting pieces go out together**, English set aside, the rest translated
  as one. Rarely needed once commits were quick.
- **MLX's buffer cache is capped at 1 GB.** Variable-length ASR windows had
  grown it to 9 GB within 90 seconds and put the machine in swap.

Still wrong: Parakeet picks the language itself, and on short or noisy Polish
it sometimes writes Russian, Spanish or Romanian; and conversational Polish
and Hungarian come out of the ASR rough enough that some translations are
guesses.

## Languages and microphones

`--languages en,pl,hu,nl` says what is spoken here. Parakeet picks the
language by itself, and on short or noisy Polish it sometimes writes Russian,
Spanish or Portuguese; a piece in none of the given languages is taken as
misheard and not spoken. Signs in the text come first, because the model is
confidently wrong about garbled Hungarian: two letters of a script none of
the languages use (Cyrillic) turn it away; a letter that all but names one of
them (ő, ł, ą) or an everyday word of one ("nem", "tudom", "nie", "niet")
lets it through; distinctive letters of another (ã, ñ, ß) turn it away. Only
then is the model asked. The translator is told the languages too. On the
8-minute stretch it dropped three Russian pieces, an Italian and a Portuguese
one, and no real speech; 25 of 26 test phrases right, the miss let through.

Pick the microphone for the people you need translated, not for yourself.
AirPods' microphones are built to hear the wearer and push everyone else
down, and using them as input usually drops their playback to call quality.
An iPhone on the table near the speakers, through Continuity, is a better
ear, with the AirPods only for listening:

    uv run translate-core live --languages en,pl,hu,nl --mic iPhone --speaker AirPods

## Clock times

A 4B model reads European clock times the English way: "halb elf" came out as
half past eleven, "sette meno cinque" as seven o'clock minus five; 3 of 10 right.
The instructions now say to write times as digits and which languages count
toward the next hour, which fixes the Romance "minus" forms and quarters but
not German and Dutch half hours, so those are rewritten to digits before the
model sees them (`um halb elf` → `um 10:30`, also `dreiviertel acht`, `Viertel
vor`, `kwart voor`). Held-out times in seven languages: 14 of 14.

## Not yet

- Any → any.
