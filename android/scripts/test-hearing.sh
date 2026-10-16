#!/usr/bin/env bash
# Run the hearing test on a connected device or emulator: install the test
# app, push Parakeet, Silero and snepssen's recordings into its files, run it,
# and print what was heard. scripts/fetch-hearing.sh first, and the samples
# from ../scripts/make-snepssen-samples.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/env.sh
./gradlew -q :hearing:assembleDebugAndroidTest
PKG=com.snepssen.hearing.test
adb install -r -t hearing/build/outputs/apk/androidTest/debug/hearing-debug-androidTest.apk >/dev/null
# Android hides files the shell puts in an app's storage from the app itself,
# so they go through /data/local/tmp and are copied in as the app (run-as,
# which a debuggable test app allows).
TMP=/data/local/tmp/hearing
adb shell mkdir -p $TMP/parakeet $TMP/samples
for f in encoder.int8.onnx decoder.int8.onnx joiner.int8.onnx tokens.txt; do
  adb shell "[ -s $TMP/parakeet/$f ]" 2>/dev/null || adb push -q ../models/android/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/$f $TMP/parakeet/
done
adb push -q ../models/android/silero_vad_v5.onnx $TMP/
adb push -q ../samples/snep_*.wav ../samples/snep_*.txt $TMP/samples/
adb shell run-as $PKG sh -c "'mkdir -p files && cp -r $TMP/parakeet $TMP/samples $TMP/silero_vad_v5.onnx files/'"
adb shell am instrument -w -e class com.snepssen.hearing.HearingTest $PKG/androidx.test.runner.AndroidJUnitRunner | tail -3
adb shell run-as $PKG cat files/hearing-report.txt
