#!/usr/bin/env bash
# Show the app interpreting one of snepssen's recordings as if it were the
# microphone (debug builds only), for trying the screens on the emulator,
# which has no microphone to speak into. Then press Live.
#
#   scripts/demo-app.sh pl     # samples/snep_pl.wav
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/env.sh
PKG=com.snepssen.interpreter
NAME="snep_${1:?a language, like pl}.wav"
adb push -q "../samples/$NAME" /data/local/tmp/$NAME
adb shell run-as $PKG sh -c "'mkdir -p files/demo && cp /data/local/tmp/$NAME files/demo/'"
adb shell rm -f /data/local/tmp/$NAME
adb shell am start -S -n $PKG/.MainActivity --es recording "$NAME" >/dev/null
echo "started with $NAME as the microphone: press Live"
