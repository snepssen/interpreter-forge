# Interpreter for Android

The Interpreter as a native Android app: Kotlin, Jetpack Compose, the same
engine design as the iPhone app, and the same voice, held to the same fixtures.

    . scripts/env.sh                         # Java 21 and the Android SDK
    ./gradlew :voice:connectedDebugAndroidTest   # on a phone or the emulator (interpreter-pixel)

## Built in phases

| | | |
|---|---|---|
| 1 | **voice** | espeak-ng built here from the pinned revision 724808c with voice-core's options; Polyphon in Kotlin; the Piper model on ONNX Runtime. Held to voice-core's fixtures: Polyphon id for id against the Python, English phonemes as Voice Forge's build gave them, Gateway Forge's 481 calls. Done: all pass on the emulator, and the epoch-200 voice speaks all eight languages at about 15x real time. |
| 2 | **hearing** | Silero VAD v5 on ONNX Runtime (the iPhone app's class, line for line) and Parakeet Ultra (moondream's post-training of v3, as the Apple apps use, int8 in sherpa-onnx's layout, checksum-verified) through sherpa-onnx, tokens joined into timed words as on the iPhone. Done: on the emulator snepssen's eight recordings are heard at 79-98% of words (v3: 71-97), 20-40x real time (`scripts/fetch-hearing.sh`, `scripts/test-hearing.sh`). |
| 3 | translating | TranslateGemma through llama.cpp (EuroLLM where nothing else fits) |
| 4 | the interpreter | segmenter, clock times, the gate, catch-up and the commentary guard, ported with the same parity cases the Swift side passes |
| 5 | the app | Jetpack Compose |

The `voice` module mirrors voice-core and is meant to move there once the app
is proven, so every Android app that speaks with snepssen gets it from one
place, as the Apple ones do. Its espeak-ng data and parity fixtures are
copied from a voice-core checkout beside translate-core at build time, never
kept twice; the speaking test takes the newest polyglot voice the way the
Apple builds do (`../apple/scripts/polyglot-voice.sh`).
