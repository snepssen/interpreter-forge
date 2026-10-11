# macOS and iOS code review — 11 October 2026

The shared Swift engine, platform audio paths, model storage, app entry points,
SwiftUI state/control wiring, packaging scripts and Python reference pipeline
were inspected. This review preserves the local work from the preceding build
and recognition-progress fixes. It does not assess a proposed UI redesign.

The principal changes are in [LiveSession](../apple/Sources/InterpreterEngine/LiveSession.swift),
[Pipeline](../apple/Sources/InterpreterEngine/Pipeline.swift),
[Audio](../apple/Sources/InterpreterEngine/Audio.swift),
[Linguist](../apple/Sources/InterpreterEngine/Linguist.swift) and
[ModelStore](../apple/Sources/InterpreterEngine/ModelStore.swift).

## Confirmed defects repaired

| Priority | Trigger and impact | Change |
| --- | --- | --- |
| P1 | Stop while recognition, translation or synthesis is running, then restart: older tasks could still play audio or change the new session's transcript. | Generation checks, an ordered event stream, cancellation checks around expensive stages, and a stopped playback guard. Closed inboxes reject later submissions. |
| P1 | Start repeatedly while the microphone permission request is suspended, or switch/delete a model during preparation: overlapping pipelines or model loads could be created. | Preparation/start guards; model controls stay disabled while the session is busy. A permission response cannot restart a stopped session. |
| P1 | A second session resets segment indices to zero but retains old transcript rows: duplicate SwiftUI IDs and merging could remove or modify rows from a previous conversation. | Transcript IDs remain unique for the lifetime of the session; each pipeline's segment indices map to its own rows. |
| P1 | Long periods without speech skip the input-buffer cleanup. Live playback also retained every synthesized clip, and English-only context grew until a foreign translation arrived. | Advance and release idle input, release live playback clips after scheduling, and bound remembered context. Recording runs retain clips for their listen-back. |
| P1 | A Gemma sliding attention cache fills its window and becomes unable to rewind: code ignored a failed trim and fed a new prompt suffix after stale tokens. | Rebuild caches when a rewind cannot be performed; reuse only tokens actually held in the cache. Empty prompts report an error. |
| P2 | The microphone meter reads a value concurrently with the audio thread writing it. | Protect meter reads and writes with the buffer lock. |
| P2 | A startup error after starting output audio or installing an input tap left audio resources active; iOS audio-session activation was not rolled back on failure. | Clean up taps, engines and the phone audio session on startup errors. |
| P2 | Phone interruptions, media-service resets and engine/route changes could leave the UI claiming to be live while the original input format was no longer usable. | Stop the session and show a restart notice. This is an explicit restart policy; seamless route recovery is not implemented. |
| P2 | A merged translation was suppressed as an echo, but only its first transcript row received that result. | Mark every merged source piece as suppressed. |
| P2 | A new voice object could select eSpeak's process-global voice while an older session was phonemizing. | Lock initialization, voice selection and phonemization globally, and select the instance's voice for each call. |
| P2 | Language recognition excluded Estonian, Latvian, Lithuanian, Maltese and Slovenian even though they were offered by the picker. | Build candidate tags from the supported-language catalogue. Candidate inclusion does not establish Apple's recognition accuracy for each language. |
| P2 | HTTP errors and invalid-size downloads could leave retained temporary files. Large partial model folders were excluded from backup only after the entire download finished. | Reject unsuccessful HTTP responses, clean temporary files and exclude the destination folder before writing model data. |
| P2 | Existing transcript rows hid loading/failure/model-selection status and retry controls. | Show those states even when previous transcript rows remain. |
| P2 | Adjusting the wall clock could disturb recording pacing and playback backlog calculations. | Use a monotonic uptime clock for audio timing. |
| P1 | Xcode can return success without producing its expected product. | iOS removes the old generated bundle and verifies the new executable, identifier and signature. macOS removes each generated executable before building and refuses packaging if it is absent; the packaged app's signature is verified. |

The earlier recognition-progress fix is retained: only the fetching stage is
labelled as downloading. Loading an existing Core ML model can report 50%
progress without downloading anything. Recognition storage uses FluidAudio's
own directory API. The installed phone was previously inspected and its
compiled recognition model directories and vocabulary were present. The
follow-up in-place installation comparison below establishes retention for
this update.

## Follow-up repairs

- **iOS lifecycle:** translation is foreground-only. The app cancels capture,
  playback and preparation when it resigns active; returning to the foreground
  can finish preparation, but restarting live capture requires pressing Live.
  Background audio is no longer declared. Cancelled inference/preparation is
  drained before another session begins. Apple's [background Metal rules](https://developer.apple.com/documentation/metal/preparing-your-metal-app-to-run-in-the-background)
  remain the reason for this policy. Cooperative cancellation is not proof
  that a physical phone has drained every GPU command before suspension; the
  lock/unlock check was subsequently confirmed by the user. Backgrounding
  during model preparation still needs its own acceptance check.
- **Mac window closure:** the shared session tracks its presented windows.
  Closing the last window stops capture and preparation; another open window
  keeps the session alive. Actual SwiftUI window-close delivery was verified
  in the rebuilt desktop app, including two windows and reopening after the
  last window closed.
- **Inference recovery:** VAD, recognition (including the final flush), judge,
  translation and synthesis errors now stop the pipeline and surface a retry
  state. Errors are not hidden by treating the judge's failure as approval or
  treating failed final recognition as an empty recording. The recording runner
  exits nonzero on terminal pipeline failure.
- **Stop at an inference boundary:** controlled stress tests found that a
  cancelled language gate could still remember context and emit a suppression
  event when its result arrived late. Cancellation is now checked after the
  gate, context update and segment judge, including a judge that returns no
  committed segments. The UI's existing generation guard provides a separate
  barrier against old-session results.
- **Python CLI:** worker exceptions reach the caller, every queued speech job
  is accounted for, and capture/playback close even when source startup fails.
  Abandoned work cannot play late audio. Incomplete token generators close and
  discard their caches. The Python prompt cache also now checks refused rewinds
  and actual cached token counts, bounds English-only context, and advances the
  input window during silence.
- **Concrete quality errors:** the apps flag the reproduced ambiguous Italian
  clock transcription and invented placeholders, preserving the source and
  withholding that piece from speech. These checks provide clarification, not
  a recovered translation; they do not silently remove initials or assume
  that `7-5` means 6:55. Empty generated translations are also flagged. Correct
  clock spellings, scores and legitimate names/placeholders remain eligible.

## Remaining issues and limits

Physical checks listed below remain necessary, including phone lifecycle,
model memory pressure and conversational accuracy. Automatic continuous
background translation is not implemented. The targeted quality checks are
not a general hallucination detector. No broad UI refinement has been applied.

## Verification

- Python baseline: `uv run pytest -q` — 51 passed. Final suite: 54 passed,
  including three new checks of the actual iOS build script using a fake Xcode:
  successful no-op builds cannot install stale products, a clean retry can
  produce a fresh app, and a real failed build never proceeds to installation.
- Shared Swift core: `swift run -q tccheck` — 53 passed.
- New engine regression suite: `cd apple && swift test` — 14 passed, no skips.
  Covers transcript identity/merging across restarts, cleared transcripts,
  stopped playback, inbox closure/draining, concurrent sample-buffer access,
  prompt-cache rewind failure and uncached tokens, empty prompts, candidate
  coverage, partial/complete model files, actual Piper synthesis and actual
  Silero VAD inference on silence.
- Shell syntax and whitespace checks passed.
- During release verification, Xcode logged a failed iOS Swift compile and
  exited with status zero. The new missing-product guard exited nonzero and
  refused to proceed. This reproduces the earlier build-script problem with
  the real toolchain, beyond the simulated no-op check.

- macOS Release: `apple/build.sh` completed; both generated executables were
  recreated, the packaged app contains its Metal library, and signature
  verification passed.
- iOS Release: `apple/iOS/build-ios.sh --no-install` completed with a newly
  generated app and verified signature. A diagnostic Xcode result bundle also
  reported `status: succeeded` and `errorCount: 0`. The script now leaves
  Xcode's output visible and retries a clean build once if an otherwise
  successful build produces no app; a second missing product still fails.
- The rebuilt Release runner completed all four local model paths below with
  no pipeline failure events. Each stereo listen-back was checked for finite
  samples, non-empty synthesized audio and an interpreter peak of 0.900.

| Model | Existing fixture | Source duration | Spoken pieces | Listen-back duration |
| --- | --- | --- | --- | --- |
| TranslateGemma 4B | German hesitation/clock-time fixture | 28.0 s | 8 | 35.1 s |
| Qwen3 4B | Fluent Spanish | 14.4 s | 5 | 19.6 s |
| Gemma 4 E2B | French run-on sentence | 15.5 s | 3 | 26.0 s |
| Gemma 4 E4B | Italian restart/correction | 12.8 s | 5 | 17.1 s |

These runs exercise both model prompting styles, judging, forced cuts,
catch-up and synthesis. The German `halb elf` case produced `10:30`. Some
runs overlapped compilation, so their timings are not latency benchmarks.
Listen-backs remain under ignored `runs/code-review-2026-10-11-*` directories.

Follow-up build and device verification results are recorded below.

## Follow-up verification

- Python: **65 passed**, including bounded worker-failure/startup cleanup,
  silence advancement, refused cache rewinds, uncached tokens, bounded context
  and cancellation of incomplete generation.
- Swift engine: **20 passed**, including injected failures in VAD, final
  recognition, judging, translation and synthesis; each stopped capture,
  emitted one terminal error and completed without hanging. Clarification
  remained nonfatal and scheduled no speech. The core's 53 checks also passed.
- The Python cache was additionally exercised with the actual local Qwen
  model across repeated translations and 100 English context inserts. It
  returned `10:30`, translated a question as a question, kept bounded history,
  and finished with 377 recorded tokens and a cache offset of 377.
- Both Release apps rebuilt and passed product/signature verification. The
  generated iOS Info.plist contains no background audio mode.
- Mac desktop: the rebuilt app reached Ready, started Live, kept capturing
  after one of two windows closed, returned to Ready after the last window
  closed and was reopened, then started/stopped another session normally.
  The test app was quit afterward. This verifies UI lifecycle delivery and
  control state; it is not a listening test of a live conversation.
- Phone: the verified app was installed **in place**, then launched. All **35
  recognition model entries** retained their paths, sizes and modification
  dates across installation, covering **483,257,242 bytes of files**. No entry
  was added, removed or changed. This establishes preservation for this
  update; it does not cover deleting the app or every possible upgrade. The
  final stop-generation guard was subsequently rebuilt, installed, and checked
  against the same baseline: all 35 entries were still unchanged.
- The user confirmed **Ready without another recognition download**, then
  **lock/unlock and restarting Live worked** on the updated phone. The console
  bridge also reported successful launch, but timed out while waiting for the
  app to exit; that timeout is not evidence of a startup or model failure.
- The rebuilt runner repeated German/TranslateGemma and Italian/Gemma E4B.
  German `10:30` and Italian `7:15` were preserved. The invented `[Name]` was
  flagged, and the ambiguous `7-5` was withheld with a repeat-time message.
  Both runs completed without terminal errors. Stereo WAVs were finite and
  nonempty, with interpreter peaks of 0.900; durations were 35.84 s and 13.71 s.
  These outcomes demonstrate targeted clarification, not repaired recognition.
- The complete Swift engine suite now has **22 passing tests, no skips**.
  Thirty controlled Stop/restart cases cover recognition, judging, language
  gating, remembering context, translation and synchronous synthesis. Each
  releases a deliberately delayed result after Stop, drains the pipeline,
  checks that capture stopped, and rejects late transcript effects or audio.
  These are injected inference boundaries, not thirty physical phone sessions.
- The actual Silero VAD processed **ten minutes of accelerated silent input**
  without a recognition call or terminal error. Input cleanup kept the final
  retained buffer at or below 40,000 samples (2.5 seconds at 16 kHz), while the
  absolute input position advanced through all 9,600,000 samples. This checks
  the shared engine's buffer policy, not a ten-minute hardware microphone run.
- The Release Qwen runner completed an **eight-minute existing mixed-language
  conversation** in real time: 149 source pieces, 53 spoken translation jobs,
  no terminal errors and no timeout. Reported source-end-to-play delay was
  **3.9 seconds median, 7.6 seconds maximum**. The 480-second stereo WAV had
  finite samples, nonempty interpreter audio and a peak of 0.900. Compilation
  overlapped part of the run, so these timings are observations on this Mac,
  not an isolated benchmark or an accuracy score.
- Memory was sampled every two seconds during that recording. Physical
  footprint snapshots in the later portion were **2.6–3.0 GB**, with a reported
  **3.2 GB peak**, on the 16 GB M1 Mac. `vmmap` includes graphics allocations
  absent from the ordinary RSS samples. This run found no escalating peak in
  those snapshots; it does not prove indefinite stability or the phone's
  memory budget. The recording runner intentionally retains synthesized clips
  and the source audio for its listen-back; live playback does not retain clips.
- Both apps were rebuilt again after the final cancellation changes. A Mac
  diagnostic build result reported **succeeded, zero errors**; its sole warning
  was MLX's deprecated cache-limit setter. The Mac executable was packaged from
  that confirmed build and passes strict signature verification. The iOS build
  also succeeded with a newly generated and verified app. It was installed in
  place, and all 35 recognition entries remained identical to the original
  baseline, again covering 483,257,242 bytes of files.

## Physical-device acceptance still needed

### Live startup follow-up

Subsequent phone screenshots showed Live immediately stopping with an audio
route warning. The broad observer treated every engine/session notification as
an interruption, including delayed startup notifications with an unchanged
route. iOS also started separate capture and playback engines on one audio
session. Capture and playback now share one engine on iOS, with the input tap
and output graph configured before starting I/O. Mac device selection retains
separate engines.

Configuration notifications are scoped to this pipeline's engines and require
an actually stopped engine. Phone route notifications compare the active
devices, sample rate and channel counts with the configuration at startup;
unchanged startup/category notifications do not stop Live. Only interruption
beginnings stop it, while media resets and real route/format changes retain the
restart policy. This follows Apple's notification semantics for
[engine configuration changes](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification)
and [audio route changes](https://developer.apple.com/documentation/avfaudio/avaudiosession/routechangenotification).

The engine suite now has **25 passing tests**, including intact startup
notifications, unrelated engines, device/rate/channel changes, interruption
begin/end, media resets and constructing capture/playback on one engine. The
new repair still requires confirmation that Live stays active on the phone;
the earlier lock/restart acceptance does not establish this later build's
startup behavior.

### Remaining checks

- iPhone: extended built-in microphone/AirPods playback; phone call or Siri
  interruption; connect/disconnect headphones; background during loading and
  warmup; selected models on the phone's actual memory budget; cold start and
  recognition while fully offline. In-place retention and live lock/restart
  have passed the checks above.
- Mac: permission denial and retry, microphone removal, output-device changes,
  rapid repeated Live/Stop during active inference, and an extended silent
  period. Window closure and a normal restart passed the desktop check.
- Both: extended mixed-language conversation with listening-backed checks of
  mistranscriptions, language changes and delay. Synthetic recordings and
  finite-audio checks verify plumbing, not conversational translation quality.
