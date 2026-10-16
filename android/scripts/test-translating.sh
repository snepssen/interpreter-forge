#!/usr/bin/env bash
# Run the translator test on a connected device or emulator: install the test
# app, copy both GGUF translators into its files (through /data/local/tmp and
# run-as: Android hides shell-pushed files from the app), run it, print the
# report. scripts/fetch-translating.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/env.sh
./gradlew -q :translating:assembleDebugAndroidTest
PKG=com.snepssen.translating.test
adb install -r -t translating/build/outputs/apk/androidTest/debug/translating-debug-androidTest.apk >/dev/null
TMP=/data/local/tmp/translating
adb shell mkdir -p $TMP
# Each file is staged, copied in, and the staged copy deleted at once: two
# copies of every model fill an emulator's 10 GB. A copy of the wrong size is
# replaced, never kept.
for f in translategemma-4b-it.Q4_K_M.gguf EuroLLM-1.7B-Instruct.Q4_K_M.gguf; do
  want=$(stat -f %z ../models/android/$f)
  have=$(adb shell run-as $PKG stat -c %s files/$f 2>/dev/null | tr -d '\r' || true)
  [ "$have" = "$want" ] && continue
  adb push -q ../models/android/$f $TMP/
  adb shell run-as $PKG sh -c "'mkdir -p files && cp $TMP/$f files/'"
  adb shell rm -f $TMP/$f
  have=$(adb shell run-as $PKG stat -c %s files/$f | tr -d '\r')
  [ "$have" = "$want" ] || { echo "error: $f arrived as $have bytes of $want (device storage full?)" >&2; exit 1; }
done
adb shell am instrument -w -e class com.snepssen.translating.TranslatorTest $PKG/androidx.test.runner.AndroidJUnitRunner | tail -3
adb shell run-as $PKG cat files/translating-report.txt
