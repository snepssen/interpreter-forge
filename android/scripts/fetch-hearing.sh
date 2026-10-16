#!/usr/bin/env bash
# What the hearing module builds and tests with, fetched rather than kept in
# git: sherpa-onnx's Android library (the variant with ONNX Runtime linked in,
# so it never clashes with the copy the voice module uses), Silero VAD v5, and
# Parakeet Ultra (int8) in sherpa-onnx's layout.
set -euo pipefail
cd "$(dirname "$0")/.."
SHERPA=1.13.8
R=libs-maven/com/k2fsa/sherpa-onnx/$SHERPA
mkdir -p "$R" ../models/android
[ -s "$R/sherpa-onnx-$SHERPA.aar" ] || curl -fsSL -o "$R/sherpa-onnx-$SHERPA.aar" \
  "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$SHERPA/sherpa-onnx-static-link-onnxruntime-$SHERPA.aar"
[ -s "$R/sherpa-onnx-$SHERPA.pom" ] || printf '<?xml version="1.0" encoding="UTF-8"?>\n<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion><groupId>com.k2fsa</groupId><artifactId>sherpa-onnx</artifactId><version>%s</version><packaging>aar</packaging></project>\n' "$SHERPA" > "$R/sherpa-onnx-$SHERPA.pom"
[ -s ../models/android/silero_vad_v5.onnx ] || curl -fsSL -o ../models/android/silero_vad_v5.onnx \
  "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad_v5.onnx"
# Parakeet Ultra: moondream's post-training of v3 (CC-BY-4.0), as the Apple
# apps use it, in sherpa-onnx's layout: sherpa-onnx's own NeMo export of the
# weights at moondream/parakeet-ultra@73175eb7, by Alexqwqw, pinned and held to
# the SHA-256 sums published with it. On snepssen's recordings it hears
# Hungarian 85% (v3: 73), German 90% (76), Dutch 80% (71), English 98% (92).
P=sherpa-onnx-parakeet-ultra-int8
REV=3e585661a664da28ff5d9293c5baaca22f930b8e
mkdir -p ../models/android/$P
for f in encoder.int8.onnx decoder.int8.onnx joiner.int8.onnx tokens.txt; do
  [ -s ../models/android/$P/$f ] || curl -fsSL -o ../models/android/$P/$f \
    "https://huggingface.co/Alexqwqw/parakeet-ultra-sherpa-onnx-int8/resolve/$REV/$f"
done
(cd ../models/android/$P && shasum -a 256 -c --status - <<SUMS) || { echo "error: Parakeet Ultra does not match its published SHA-256" >&2; exit 1; }
4ef28650a81a38bc05124745dcfe776ff2bca7ac1d6009893a0f87d64bdf8b43  encoder.int8.onnx
94373c6405c8149d1c9d1e9862514e0e3e88dab1c7de18fac9d5df9c6ba5efdd  decoder.int8.onnx
8a71aaccfdba3d451775507a889afd2257d2e754463fd81095a8c8f290f924c2  joiner.int8.onnx
SUMS
ls -la "$R" ../models/android ../models/android/$P
