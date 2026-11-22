# Python rig: Parakeet v3 or Ultra — 21 November 2026

The apps recognise speech with Parakeet Ultra; the Python rig still used
Parakeet TDT 0.6B v3. This checks whether an MLX build of Ultra is the real
thing, whether it beats v3 on the rig's audio, and whether it behaves like the
apps' Ultra. **Result: it does all three, so the rig now defaults to Ultra**
(`--asr v3` keeps the old model).

## The model

[`pisar/parakeet-ultra-mlx`](https://huggingface.co/pisar/parakeet-ultra-mlx),
pinned to revision `67b18a404d0dd8335fbab4fa2a0e54d5349f68de`: the
[`moondream/parakeet-ultra`](https://huggingface.co/moondream/parakeet-ultra)
weights (revision `73175eb7`) renamed from Hugging Face `ParakeetForTDT` into the
NeMo/MLX layout parakeet-mlx reads, at bf16. parakeet-mlx 0.5.3's
`from_pretrained` loads it unchanged; `asr.py` resolves the pinned revision to
its downloaded snapshot. ~1.2 GB in the shared Hugging Face cache
(`~/Resources/huggingface-hub`).

Upstream is a transformers checkpoint, not a `.nemo` file, so parakeet-mlx's
NeMo converter does not apply to it directly; a conversion of our own would be
the same renaming the card documents. Its card says the upstream accuracy
gains were not reproduced; that was on synthetic speech where both models
saturated. Here they did not saturate, and the gains show (below). The weights
were not compared tensor by tensor with upstream; the evidence that they are
Ultra is behavioural: on 32 clips its text differs from v3's on 21, and it
repeats errors peculiar to the apps' Ultra (Polish `nie o dziewiątej` →
`dnia dziewiątej`, Dutch `vanwege` → `van weven`).

## Method

- Apple M1, 16 GB, macOS 27.2.1. parakeet-mlx 0.5.3 on the GPU, bf16. Whole-clip
  transcription (`scripts/mlx-recognition.py`), one warm-up pass first, no
  language hint. Same WAV bytes for every model.
- **Polyglot set**: the 32 saved clips of `runs/recognition-2026-10-16/audio`
  (snepssen's synthetic voice, four per language, 311.65 s), so the apps'
  Ultra transcripts from that run compare directly; not re-synthesised.
- **Recordings**: `samples/snep_*.wav`, the eight longer snepssen recordings
  (179 s, one per language) the Android check also used. The apps' Ultra ran on
  them today through `tcasr` (FluidAudio, Core ML, Neural Engine).
- WER from `scripts/check-polyglot-recognition.py`: word edits / reference
  words, case and punctuation ignored, numbers not rewritten (so the app's
  `8` for `ocho` counts as an error).
- Compute excludes model loading. One pass each; machine activity not
  controlled. Synthetic speaker, clean audio: no room, noise or second voice.

## Polyglot set (32 clips, WER)

| Language | Words | MLX v3 | MLX Ultra | App Ultra (16 Oct) |
|---|---:|---:|---:|---:|
| English | 91 | 2.2% | **0.0%** | 2.2% |
| Polish | 70 | 14.3% | 14.3% | 17.1% |
| Hungarian | 63 | 33.3% | **27.0%** | 27.0% |
| German | 90 | **4.4%** | 6.7% | 6.7% |
| Dutch | 90 | 5.6% | 4.4% | **2.2%** |
| French | 112 | 11.6% | **8.0%** | 9.8% |
| Spanish | 87 | 44.8% | **1.1%** | 3.4% |
| Italian | 65 | 7.7% | 7.7% | 7.7% |
| **All** | 668 | 14.8% (99 edits) | **7.8%** (52) | 8.7% (58) |
| Compute | | 21.8 s (14×) | 20.1 s (16×) | 5.3 s (59×) |

v3's Spanish score is one clip: halfway through the long Spanish passage it
switched to English (`A partir of lunes abrimos at the 8 of the machine`, 37
edits). Without that clip v3 is still behind, 62 edits to Ultra's 52.

## Recordings (8 clips, WER)

| Language | Words | MLX v3 | MLX Ultra | App Ultra (today) |
|---|---:|---:|---:|---:|
| German | 50 | 6.0% | 6.0% | 8.0% |
| English | 51 | 7.8% | **5.9%** | 11.8% |
| Spanish | 48 | 56.2% | **0.0%** | 10.4% |
| French | 66 | 6.1% | **3.0%** | **3.0%** |
| Hungarian | 33 | 15.2% | **9.1%** | **9.1%** |
| Italian | 28 | **0.0%** | 7.1% | **0.0%** |
| Dutch | 49 | 18.4% | 10.2% | **4.1%** |
| Polish | 40 | 12.5% | 12.5% | 12.5% |
| **All** | 365 | 15.6% (57) | **6.3%** (23) | 7.4% (27) |
| Compute | | 10.6 s (17×) | 10.1 s (18×) | 3.1 s (57×) |

v3 fell into English on the whole Spanish recording too (not in the rig's short windows; see below). The app's Spanish errors
are mostly Portuguese spellings (`horário`, `não`, `perguntas`) plus numerals.

## Does the MLX Ultra match the apps' Ultra?

Roughly, yes: 7.8% against 8.7% on the polyglot set, 6.3% against 7.4% on the
recordings, with the same characteristic mistakes. Text is identical on 17 of
32 polyglot clips (v3 matches the app on 10). The remaining differences are
what bf16 MLX against FluidAudio's Core ML build should give, and they cut
both ways. One pattern matters for an interpreter: MLX Ultra lost two
negations that the app kept, Dutch `niet om negen uur` → `Mid om negen uur`
and Italian `non alle sette` → `una le sette`. v3 lost the Dutch one as well
(`Miet`). The app lost none on these clips, but the 16 October run shows it
losing Polish `nie o dziewiątej` the same way. So treat the rig as a close
stand-in for the app's recognizer, not an exact one: differences of a word or
two per clip are noise between the two builds, not evidence about the app.

Speed is not comparable: the app's Neural Engine path is 3–4× faster than MLX
on the GPU here, for both v3 and Ultra. Ultra costs the rig nothing over v3.

## Through the rig's own pipeline

`translate-core file samples/snep_*.wav` (rolling-window recognition, the
judge, Qwen3-4B translation, Piper voice; simulated clock), once per model.
English is recognised but kept quiet, so it has no lag row.

| Recording | Pieces spoken v3 / Ultra | Median lag v3 | Median lag Ultra | Max lag v3 | Max lag Ultra |
|---|---:|---:|---:|---:|---:|
| German | 6 / 6 | 4.7 s | 4.1 s | 5.5 s | 5.4 s |
| Spanish | 5 / 5 | 3.6 s | 3.5 s | 4.7 s | 4.3 s |
| French | 4 / 4 | 6.0 s | 5.3 s | 6.8 s | 5.8 s |
| Hungarian | 5 / 7 | 5.0 s | 4.2 s | 6.4 s | 5.8 s |
| Italian | 4 / 4 | 3.6 s | 3.4 s | 4.0 s | 4.1 s |
| Dutch | 6 / 5 | 4.6 s | 4.2 s | 6.1 s | 6.7 s |
| Polish | 5 / 5 | 3.3 s | 2.8 s | 3.8 s | 3.4 s |

Mean recognition pass: 252–360 ms with Ultra, 257–370 ms with v3, so the lag
differences come from segmentation (where punctuation and word timing let the
segmenter cut), not compute. One run each; read them as "no worse", not as a
measured improvement. In short windows v3 did not fall into English on the
Spanish recording; both models slipped into Portuguese spellings there
(`horário`, `não`, `perguntas`), as the app's Ultra did on the whole clip. The
English drift is a long-context failure, which matters for whole-file
transcription more than for the live rig.

## Licence

Parakeet Ultra is © moondream, a post-training of NVIDIA's
[parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3);
both are CC-BY-4.0. The MLX copy is pisar's format conversion (same licence,
no other changes claimed). The rig downloads the weights at run time and does
not redistribute them. Anything that does redistribute them must credit NVIDIA
and moondream and name the conversion and revision, as
[the permissions review](publication-permissions-2026-10-16.md) says.

## Reproduce

```sh
R=runs/recognition-NEW
uv run python scripts/mlx-recognition.py v3    runs/recognition-2026-10-16/audio $R/mlx-v3.jsonl
uv run python scripts/mlx-recognition.py ultra runs/recognition-2026-10-16/audio $R/mlx-ultra.jsonl
python3 scripts/check-polyglot-recognition.py score runs/recognition-2026-10-16/parakeet.jsonl $R/mlx-*.jsonl
# the eight recordings (only WAVs with a .txt beside them are scored)
uv run python scripts/mlx-recognition.py ultra samples $R/samples-mlx-ultra.jsonl   # and v3
# the app's recognizer reads every WAV in a folder: give it one holding only samples/snep_*.{wav,txt}
# (build tcasr as in recognition-polyglot-2026-10-16.md)
apple/.build/out/Build/Products/Debug/tcasr parakeet-ultra SNEP_FOLDER $R/samples-app-ultra.jsonl
uv run translate-core file samples/snep_*.wav --asr v3 --out $R/file-v3
uv run translate-core file samples/snep_*.wav --out $R/file-ultra
```

Raw JSONL, logs and summaries stay local in `runs/recognition-mlx-2026-11-21/`.
