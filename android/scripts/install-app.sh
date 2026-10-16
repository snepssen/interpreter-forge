#!/usr/bin/env bash
# Install the app on a connected phone or the emulator, for development:
# builds it, and with --models copies the local models in (through
# /data/local/tmp and run-as) so a test run needn't download 3 GB. A user's
# phone downloads them on first launch.
#
#   scripts/install-app.sh [--models TRANSLATE_GEMMA|EURO_LLM]
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/env.sh
./gradlew -q :app:assembleDebug
PKG=com.snepssen.interpreter
# The test apps' copies of the models would fill an emulator's 10 GB.
for other in com.snepssen.engine.test com.snepssen.hearing.test com.snepssen.translating.test; do
  adb uninstall $other >/dev/null 2>&1 || true
done
adb install -r app/build/outputs/apk/debug/app-debug.apk >/dev/null
echo "installed $PKG"
[ "${1:-}" = "--models" ] || exit 0
case "${2:-TRANSLATE_GEMMA}" in
  TRANSLATE_GEMMA) GGUF=translategemma-4b-it.Q4_K_M.gguf ;;
  EURO_LLM) GGUF=EuroLLM-1.7B-Instruct.Q4_K_M.gguf ;;
  *) echo "usage: $0 [--models TRANSLATE_GEMMA|EURO_LLM]" >&2; exit 2 ;;
esac
M=../models/android
TMP=/data/local/tmp/app
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
  stage $M/sherpa-onnx-parakeet-ultra-int8/$f parakeet-ultra/$f
done
stage $M/$GGUF $GGUF
adb shell run-as $PKG sh -c "'mkdir -p shared_prefs && printf \"<?xml version=\\\"1.0\\\" encoding=\\\"utf-8\\\"?><map><string name=\\\"translationModel\\\">${2:-TRANSLATE_GEMMA}</string></map>\" > shared_prefs/interpreter.xml'"
echo "models copied in; $PKG will use ${2:-TRANSLATE_GEMMA}"
