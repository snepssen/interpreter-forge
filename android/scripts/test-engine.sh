#!/usr/bin/env bash
# Run the engine tests on a connected device or emulator: the language
# detector against the iPhone's, then snepssen's recordings through the whole
# live loop. Copies Parakeet, the translator and the recordings into the test
# app's files (through /data/local/tmp and run-as: Android hides shell-pushed
# files from the app). The other modules' test apps are removed first: their
# copies of the models would fill an emulator's 10 GB.
#
#   scripts/test-engine.sh [TRANSLATE_GEMMA|EURO_LLM] [instrumentation args...]
#   e.g. scripts/test-engine.sh TRANSLATE_GEMMA -e recordings pl,hu -e hearing 2 -e translating 2
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/env.sh
MODEL="${1:-TRANSLATE_GEMMA}"
shift || true
case "$MODEL" in
  TRANSLATE_GEMMA) GGUF=translategemma-4b-it.Q4_K_M.gguf ;;
  EURO_LLM) GGUF=EuroLLM-1.7B-Instruct.Q4_K_M.gguf ;;
  *) echo "usage: $0 [TRANSLATE_GEMMA|EURO_LLM]" >&2; exit 2 ;;
esac
./gradlew -q :engine:assembleDebugAndroidTest
PKG=com.snepssen.engine.test
for other in com.snepssen.hearing.test com.snepssen.translating.test; do adb uninstall $other >/dev/null 2>&1 || true; done
adb install -r -t engine/build/outputs/apk/androidTest/debug/engine-debug-androidTest.apk >/dev/null
TMP=/data/local/tmp/engine
M=../models/android
# Each file is staged, copied in, and the staged copy deleted at once. A copy
# of the wrong size is replaced, never kept.
stage() {  # source, destination within files/
  local from=$1 to=$2 want have
  want=$(stat -f %z "$from")
  have=$(adb shell run-as $PKG stat -c %s "files/$to" 2>/dev/null | tr -d '\r' || true)
  [ "$have" = "$want" ] && return
  adb shell mkdir -p $TMP
  adb push -q "$from" $TMP/staged
  adb shell run-as $PKG sh -c "'mkdir -p \$(dirname files/$to) && cp $TMP/staged files/$to'"
  adb shell rm -f $TMP/staged
  have=$(adb shell run-as $PKG stat -c %s "files/$to" | tr -d '\r')
  [ "$have" = "$want" ] || { echo "error: $to arrived as $have bytes of $want (device storage full?)" >&2; exit 1; }
}
for f in encoder.int8.onnx decoder.int8.onnx joiner.int8.onnx tokens.txt; do
  stage $M/sherpa-onnx-parakeet-ultra-int8/$f parakeet/$f
done
# Only the translator under test: both would not fit beside Parakeet.
for other in translategemma-4b-it.Q4_K_M.gguf EuroLLM-1.7B-Instruct.Q4_K_M.gguf; do
  [ $other = $GGUF ] || adb shell run-as $PKG rm -f files/$other
done
stage $M/$GGUF $GGUF
for f in ../samples/snep_*.wav; do stage "$f" "samples/$(basename "$f")"; done
adb shell am instrument -w -e class com.snepssen.engine.DetectorTest $PKG/androidx.test.runner.AndroidJUnitRunner | tail -2
adb shell am instrument -w -e class com.snepssen.engine.LiveTest -e model "$MODEL" "$@" $PKG/androidx.test.runner.AndroidJUnitRunner | tail -3
adb shell run-as $PKG cat files/live-report.txt
