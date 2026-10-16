#!/usr/bin/env bash
# What the hearing module builds and tests with, fetched rather than kept in
# git: sherpa-onnx's Android library (the variant with ONNX Runtime linked in,
# so it never clashes with the copy the voice module uses), Silero VAD v5, and
# Parakeet TDT 0.6B v3 (int8) as sherpa-onnx exports it.
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
P=sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8
if [ ! -d "../models/android/$P" ]; then
  curl -fsSL "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$P.tar.bz2" | tar -xj -C ../models/android
fi
ls -la "$R" ../models/android ../models/android/$P
