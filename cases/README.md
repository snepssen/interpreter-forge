# Cases every implementation is held to

The Interpreter's logic exists three times: Python (`src/translate_core`,
the research rig and the reference), Swift (`apple/Sources/InterpreterCore`)
and Kotlin (`android/core`). These files are the cases all three answer,
read by `tests/test_*.py`, `apple/Sources/tccheck` and
`android/core/src/test/.../ParityTest.kt`. A case is added here once, and
every language is held to it; a language that answers differently fails.

They are also the spec a future native shell's core must pass.

## segmenter.json

Each case builds a segmenter with `adapt` off and the `config` given (fields
in camelCase, as Swift and Kotlin spell them; Python converts), and, when
`judge` is present, a judge that says a text is complete when, with `.` and
`,` trimmed, it ends with one of those endings (`[]` refuses everything).

`startMark`, when present, sets the mark before anything else. Each step
calls `step(now, words, silence)`. `words` is a list of groups:
`{"text": "a b c", "start": 0, "step": 0.4}` is one word every `step`
seconds from `start`, each lasting 0.3 s, which is what every case was
written with. `expect`, when present, is what that step commits: `[]` for
nothing, or one object per segment with the `text` and/or `reason` it must
have. `asked`, when present, is every text the judge has been asked so far.

`after` checks the segmenter once the steps are done: its `mark`, the
`pending` words' texts, and everything the judge was `asked`. `newWords`
then calls `new_words` with explicit `[text, start, end]` words (offsets
from the mark when `fromMark` is true) and expects the texts it keeps.

One segmenter case stays in code: the long pause adapting to a hesitant
speaker compares thresholds, not outputs.

## The others

`clock.json`: `becomeDigits` pairs (input, output) and `leftAlone` inputs for
`Clock.normalise`. `echoes.json`: pairs that are and are not echoes.
`language-evidence.json`: `true`, `false`, `null`, or `"notFalse"` (anything
but false) for `Languages.evidence(text, expected)`. `catch-up.json`:
`Backlog`'s `brief(backlog)` and `pace(backlog)`.

`why` fields carry the reason a case exists; the code ignores them.
