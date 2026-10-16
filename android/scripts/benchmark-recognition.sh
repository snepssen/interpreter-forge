#!/usr/bin/env bash
# Recognition only, using the exact app-voice corpus generated on the Mac.
# Usage: scripts/benchmark-recognition.sh ../runs/recognition-DATE/audio ../runs/recognition-DATE/android.jsonl
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/env.sh
CORPUS="${1:?supply the generated audio directory}"
REPORT="${2:?supply a new JSONL result path}"
[ ! -e "$REPORT" ] || { echo "refusing to overwrite $REPORT" >&2; exit 1; }
[ "$(find "$CORPUS" -name '*.wav' | wc -l | tr -d ' ')" = 32 ] || { echo "expected 32 WAV files" >&2; exit 1; }
# Check before installation; never clear the installed app or its models.
AVAILABLE=$(adb shell df -k /data | tail -1 | awk '{print $4}')
[ "$AVAILABLE" -gt 1200000 ] || { echo "Need 1.2 GB free in /data; installed app and models left intact." >&2; exit 1; }
./gradlew -q :hearing:assembleDebugAndroidTest
PKG=com.snepssen.hearing.test
adb install -r -t hearing/build/outputs/apk/androidTest/debug/hearing-debug-androidTest.apk
adb shell run-as "$PKG" mkdir -p files/parakeet files/benchmark
# Stream directly into test-owned storage: no second copy of the model.
for name in encoder.int8.onnx decoder.int8.onnx joiner.int8.onnx tokens.txt; do
  adb exec-in run-as "$PKG" sh -c "cat > files/parakeet/$name" < "../models/android/sherpa-onnx-parakeet-ultra-int8/$name"
done
for file in "$CORPUS"/*.wav "$CORPUS"/*.txt; do
  adb exec-in run-as "$PKG" sh -c "cat > files/benchmark/$(basename "$file")" < "$file"
done
adb shell am instrument -w -e class com.snepssen.hearing.HearingTest#polyglotBenchmark \
  "$PKG/androidx.test.runner.AndroidJUnitRunner" | tee "${REPORT%.jsonl}.instrumentation.log"
adb shell run-as "$PKG" cat files/benchmark.jsonl > "$REPORT"
[ "$(wc -l < "$REPORT" | tr -d ' ')" = 32 ] || { echo "incomplete benchmark; inspect instrumentation log" >&2; exit 1; }
