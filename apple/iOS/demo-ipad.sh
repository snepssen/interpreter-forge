#!/usr/bin/env bash
# Show the installed app interpreting a recording as if it were the
# microphone, silently: no audio session, so nothing is taken from headphones
# or music, and the interpreter's voice is not played. For checking screens on
# a device without sound in the room.
#
#   iOS/demo-ipad.sh ../demo/media/pl-podcast.wav [device]   # device: a name or UDID; default the first iPad
set -euo pipefail
CLIP="${1:?a WAV file}"
DEVICE="${2:-}"
if [ -z "$DEVICE" ]; then
  DEVICE="$(xcrun devicectl list devices 2>/dev/null | grep -E "iPad" | grep -E "available|connected" | head -1 \
    | awk '{for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) print $i}' || true)"
fi
[ -n "$DEVICE" ] || { echo "no iPad connected" >&2; exit 1; }
NAME="$(basename "$CLIP")"
xcrun devicectl device copy to --device "$DEVICE" --source "$CLIP" --destination "Documents/$NAME" \
  --domain-type appDataContainer --domain-identifier com.snepssen.interpreter -q
xcrun devicectl device process launch --terminate-existing --device "$DEVICE" \
  --environment-variables "{\"INTERPRETER_DEMO\": \"$NAME\"}" com.snepssen.interpreter -q
echo "playing $NAME into the app; it presses Live by itself once ready"
