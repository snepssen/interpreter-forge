#!/usr/bin/env bash
# Put Silero VAD at the given path (default: models/silero_vad.onnx): the
# v6.2 release, checked against its SHA-256. Fetched only when the file is
# missing or is some other version; build.sh and iOS/build-ios.sh call this,
# and src/translate_core/vad.py pins the same file.
#
# It used to come from silero-vad's master branch, so a build took whatever
# model was newest that day. v6.2 is the file master served until now.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="${1:-$REPO/models/silero_vad.onnx}"
URL="https://raw.githubusercontent.com/snakers4/silero-vad/v6.2/src/silero_vad/data/silero_vad.onnx"
SHA=1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3

matches() { [ -s "$1" ] && [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$SHA" ]; }
matches "$DEST" && exit 0
[ -s "$DEST" ] && echo "replacing ${DEST}: not Silero VAD v6.2" >&2
mkdir -p "$(dirname "$DEST")"
curl -fsSL -o "$DEST.part" "$URL" || { rm -f "$DEST.part"; echo "error: could not fetch Silero VAD v6.2" >&2; exit 1; }
matches "$DEST.part" || { rm -f "$DEST.part"; echo "error: the fetched Silero VAD does not match its SHA-256" >&2; exit 1; }
mv "$DEST.part" "$DEST"
