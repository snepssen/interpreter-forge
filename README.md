# interpreter-forge

Live speech interpretation that works like a human interpreter rather than a
walkie-talkie. It listens continuously, waits until a thought is complete, and
passes it on to be translated and spoken in your ear while it keeps listening.
Everything runs locally.

    mic ─▶ VAD ─▶ segmenter ─▶ translate ─▶ speak ─▶ headphones
                  ▲      │
                  └ ASR ◀┘  re-reads the uncommitted tail every 0.5 s

**European languages → English**, on Apple Silicon Macs and iPhones; the apps
also interpret into Polish, Hungarian, German, Dutch, French, Spanish or Italian.

| stage     | model                                        |
|-----------|----------------------------------------------|
| VAD       | Silero VAD v5 (ONNX)                         |
| ASR       | Parakeet TDT 0.6B v3 via `parakeet-mlx` — 25 European languages, punctuated |
| translate | Qwen3-4B-Instruct-2507, 4-bit MLX, carrying the last three pieces as context |
| speak     | Piper; the Python rig uses the voice-forge voice in `../voice-forge`, the apps the polyglot snepssen from `../voice-polyglot` |

## The Mac app

`apple/` is the native app the Python here measures for: SwiftUI, macOS 14+,
with the same engine and views shared by the iPhone app.

    scripts/fetch-models.sh        # the translation model, if not done already
    apple/build.sh                 # checks, then apple/Interpreter.app

Press **Live** (or Space) and the feed fills with what is said around you,
translated, with each line's lag; English is shown dimmed and kept quiet. Any
language is translated by default; naming the languages spoken here makes
anything else count as misheard (useful where Polish keeps coming out as
Russian, but it silences a Romanian guest, so it is opt-in). Pick the mic (an
iPhone on the table through Continuity hears the room better than AirPods)
and the output from the top bar. Use **Transcript options** to show or hide
English context or clear a stopped conversation. Translations appear in cards,
with the original speech underneath and a delay label. The first launch downloads Parakeet (a few
hundred MB). Native Mac and iPhone apps now use **Parakeet Ultra** by default.
In **Models → Speech recognition**, choose **Whisper large-v3 Turbo** to try
Argmax's recommended `large-v3-v20240930_626MB` variant instead. Recognition
selection is remembered, and only one recognizer is loaded at a time.
Whisper exposes 100 recognition languages; Parakeet Ultra exposes 25. This
does not make every language equally accurate, or expand TranslateGemma's
55-language translation coverage. See [recognition options](docs/recognition-options.md).

You choose the translation model: a picker on first launch, and a model
manager (the gear) to download, switch or delete them later, since not
everyone needs the same one and a smaller model runs smoother. Measured with
`scripts/compare-models.py` (26 lines across 13 languages, the judge's 17
cases) and `tcrun` (8 minutes of fast Polish and Hungarian):

| model | meaning errors | judge | peak memory | median lag in conversation |
|---|---|---|---|---|
| TranslateGemma 4B (recommended) | 0 of 26, the most natural | — | 2.6 GB | 6.7 s |
| Qwen3 4B | 3 | 17/17 | 2.8 GB | 4.4 s |
| Gemma 4 E4B | 1, nearly as natural | 13/17 | 4.7 GB (Mac, 12 GB iPhones) | — |
| Gemma 4 E2B | 5 | 12/17 | 3.0 GB | — (fastest per line, 0.6 s) |

TranslateGemma is told the source language, by Apple's on-device language
detector (30 of 35 test lines; misses only on two-word or garbled pieces,
where it falls back to the last language it was sure of). The same detector
now decides what is English, and in restricted mode what is misheard, so the
gate is the same whichever model is loaded. Only a general model judges when
a thought is complete; with TranslateGemma pieces are cut on pauses,
punctuation and the 5 s ceiling, which is why it speaks later. Gemma 4 has
its thinking switched off: left on, it reasons for seconds over every line.

The iPhone app (`apple/iOS/build-ios.sh`, iOS 17+) is the same engine and
views. On an iPhone 17 (8 GB) the 4B translation model fits with the
increased-memory entitlement, at 3.4–4.0 s lag in a first real test. The
phone's own mic listens and AirPods play the English in full quality.
Translation currently requires keeping the phone app active. Locking the
screen, switching apps or another interruption pauses capture and playback;
return to Interpreter and press Live to restart. In-flight model work is
cancelled and drained before another session can start. The app does not
claim background GPU support. Ready without another recognition download and
lock/unlock followed by restarting Live were checked on the updated iPhone.

`build-ios.sh` removes the previous generated app before building, then checks
that a new bundle contains the expected executable and bundle identifier and
passes signature verification before installing. `--no-install` runs those
same checks without touching the phone. Dependency and compilation caches stay
in place. The explicit **InterpreterPhone** scheme selects the iOS app;
the Swift package's similarly named Mac executable is a different target.

The phone uses one audio engine for capture and playback. Delayed startup
notifications with an unchanged route do not stop Live; actual device/format
changes, stopped engines, interruptions and media resets still ask for a
restart. The updated phone was checked to stay live and display speech.

See [the code review](docs/code-review-2026-10-11.md) for engine fixes and
verification, and [the UI notes](docs/ui-polish-2026-10-11.md) for the shared
Mac/iPhone interface changes.

Parakeet models use FluidAudio's Application Support directory. Ultra is a
different set of weights from v3, so updating to it downloads about 630 MB
once; the old v3 cache is retained. Whisper has a separate app-owned cache,
excluded from iCloud backup, with a completion record checked before loading.
After its models and tokenizer have loaded successfully, cached launches
skip the model downloader. An interrupted download cannot mark the cache complete.
The installer has no uninstall step. An in-place update was checked on the
phone: all 35 recognition-file entries retained their paths, sizes and
modification dates, and the user confirmed Ready without another download.
Download progress is shown only during
model fetching; loading cached models is labelled “Loading speech recognition”.
The storage display reads the same directory as the recognizer. To check
retention on a phone, note the recognition storage size, install over the
existing app without deleting it, and compare the size before starting a
session. Then test a session offline to confirm the models are reusable.

| | Python (MLX) | Swift app |
|---|---|---|
| speech recognition | MLX on the GPU, 300–800 ms a pass | FluidAudio on the Neural Engine, 75–161 ms |
| translation | Qwen3-4B, MLX | the same model, MLX Swift, ~1 s |
| voice | Piper (onnxruntime) | Polyphon (voice-polyglot's corrected espeak-ng, ported), Piper on ONNX Runtime |
| scheduling | translation first: one GPU | side by side: ASR on the Neural Engine, translation on the GPU |

The timings above were measured with the previous Parakeet v3 recognizer;
they are not a benchmark of Ultra or Whisper. The Python comparison engine
continues to use v3.

`InterpreterCore` is the Python logic ported (segmenter, clock times, language
evidence, echoes, catch-up); `tccheck` asks every Python test again and gets
the same answers. `tcrun <audio>` plays a recording through the real Swift
pipeline at speaking pace and prints each piece with its lag, as `live --from`
does here. Measured that way, German median lag is 3.7 s in both, and the
fast Polish and Hungarian stretch of the kitchen recording 4.4 s in Swift
against 4.8 s in Python.

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

In the apps, catching up by saying less is a choice, **Settings → Voice →
Summarise to keep up**, off by default. Uneven speech is meant to queue: a
pause, a slow build-up or a speaker thinking aloud is context the next piece
is translated with, not something to cut. Some listeners would rather follow
along than hear all of a long story, and for them the gist ("complaining about
back pain and their boss") is the point. It needs a model that takes
instructions (Qwen, Gemma 4); TranslateGemma always translates in full, and a
piece is no longer marked shortened when it wasn't. The speed-up below stays
on: it loses nothing. `tcrun --summarise` measures the same way. What follows
is the Python rig, where both are on.

The English can take longer to say than the original, and a speaker who never
stops gives no room to catch up. So, like a human interpreter, it says less and
says it faster once English is queueing: past 1.5 s of backlog the next piece is
translated for the gist, and past 1 s the voice speeds up, to at most 1.3x.
The voice graph rounds each phoneme up to a whole frame, so a request for 1.1x
delivers about 1.05x and 1.4x about 1.35x. On the French run-on this brings the
interpreter's speech from 19.1 s down to 16.1 s against 15.5 s of source, and the
worst lag from 14.9 s to 12.4 s; what remains is the 11 s before the first piece
could be cut at all. `--no-catch-up` turns it off.

## Interpreting into another language

The apps speak through the polyglot snepssen voice (`../voice-polyglot`),
trained on English, Polish, Hungarian, German, Dutch, French, Spanish and
Italian. The language menu's **Into** picks the listener's language, the
one everything is interpreted into; that language then takes English's place
below: understood, kept as context and not spoken, while English becomes one
more language to translate. The prompts name it, and TranslateGemma is given
it as its target code.

The voice phonemizes through `Polyphon`, from the shared
[voice-core](https://github.com/snepssen/voice-core) package: a port of voice-polyglot's
`polyphon.py` held to it id for id (voice-core's tests, fixtures generated from
the Python), and speaks each language at the length scale its export carries:
the Suno-made languages were read faster than its English, and the scales,
picked by ear, even them out. `build.sh` and `iOS/build-ios.sh` bundle the
newest voice (`apple/scripts/polyglot-voice.sh`): voice-polyglot's newest
export where it is trained, anywhere else its latest
[GitHub Release](https://github.com/snepssen/voice-polyglot/releases), fetched
into `models/voice/` and checked against its SHA256SUMS. Every build carries
the newest voice. **Settings → Language → Untrained languages** (off by
default) also offers Parakeet's other European languages, read through plain
espeak-ng with no corrections. `tcrun --into hu` runs a recording the same way.

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

Recording checks also exposed limits beyond that test set: recognition can
write Italian `sette meno cinque` as the ambiguous `7-5`, and a hesitation
misheard as `M.` can become an invented `[Name]` in translation. The Swift apps
show a clarification message for these detected cases and do not speak them.
They preserve the source transcript; the checks neither recover a missing
meaning nor establish general translation accuracy.

## Not yet

- Any → any.

## Licence

The interpreter's source is licensed under the GNU General Public License,
version 3 ([LICENSE](LICENSE)), as are voice-core and voice-polyglot, which
it builds on, and espeak-ng and Piper inside them.

The models it downloads are not part of this repository and keep their own
terms: Parakeet Ultra (CC BY 4.0), TranslateGemma (Gemma terms), EuroLLM
(Apache 2.0), Silero VAD (MIT). The snepssen voice is covered in
voice-polyglot's README: it was trained on Suno-generated speech, and is not
licensed for redistribution until Suno has said it may be.
