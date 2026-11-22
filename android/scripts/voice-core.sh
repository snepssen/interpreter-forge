#!/usr/bin/env bash
# Print a folder holding voice-core's espeak-ng data and parity fixtures, at
# the revision apple/Package.resolved pins, so the Android voice ships the same
# data the Apple builds and their tests use. voice/build.gradle.kts runs this.
#
# The archive of that revision is fetched from GitHub once (about 14 MB) and
# kept in android/build/voice-core/<revision>/. Nothing beside this repository
# is read unless asked for:
#
#   VOICE_CORE=../../voice-core ./gradlew ...   use a voice-core checkout instead
set -euo pipefail
ANDROID="$(cd "$(dirname "$0")/.." && pwd)"
NEED="Sources/VoiceCore/Resources/espeak-ng-data"

if [ -n "${VOICE_CORE:-}" ]; then
  [ -d "$VOICE_CORE/$NEED" ] || { echo "error: VOICE_CORE=$VOICE_CORE has no $NEED" >&2; exit 1; }
  cd "$VOICE_CORE" && pwd; exit 0
fi

REV="$(python3 -I - "$ANDROID/../apple/Package.resolved" <<'PY'
import json, sys
pins = {p["identity"]: p["state"] for p in json.load(open(sys.argv[1], encoding="utf-8"))["pins"]}
print(pins["voice-core"]["revision"])
PY
)"
OUT="$ANDROID/build/voice-core/$REV"
if [ -d "$OUT/$NEED" ] && [ -d "$OUT/Tests/VoiceCoreTests/Fixtures" ]; then echo "$OUT"; exit 0; fi

echo "fetching voice-core ${REV} (the revision apple/Package.resolved pins)" >&2
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -fsSL "https://github.com/snepssen/voice-core/archive/$REV.tar.gz" -o "$WORK/voice-core.tar.gz" || {
  echo "error: could not fetch voice-core $REV from GitHub; set VOICE_CORE to a checkout to build offline" >&2; exit 1; }
mkdir "$WORK/out"
tar -xzf "$WORK/voice-core.tar.gz" -C "$WORK/out" --strip-components=1 \
  "voice-core-$REV/$NEED" "voice-core-$REV/Tests/VoiceCoreTests/Fixtures"
mkdir -p "$(dirname "$OUT")"
rm -rf "$OUT" && mv "$WORK/out" "$OUT"
echo "$OUT"
