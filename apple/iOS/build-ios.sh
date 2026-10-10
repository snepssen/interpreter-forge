#!/usr/bin/env bash
# Build the iPhone app and install it on a connected iPhone.
#
#   iOS/build-ios.sh            # build, install on the first connected iPhone
#   iOS/build-ios.sh --no-install
#
# The voice and espeak-ng data come from voice-forge beside translate-core, the
# VAD model from models/. The translation model is not bundled: the app fetches
# it on first launch (2.3 GB, best on Wi-Fi).
set -euo pipefail
cd "$(dirname "$0")"
IOS="$(pwd)"
REPO="$(cd ../.. && pwd)"
VOICEFORGE="$(dirname "$REPO")/voice-forge/macos/Sources/VoiceForgeTTS/Resources"
VOICE="en_US-snepssen-medium"

mkdir -p Resources
cp "$VOICEFORGE/$VOICE.onnx" "$VOICEFORGE/$VOICE.onnx.json" Resources/
rsync -a --delete "$VOICEFORGE/espeak-ng-data/" Resources/espeak-ng-data/
[ -s "$REPO/models/silero_vad.onnx" ] || curl -fsSL -o "$REPO/models/silero_vad.onnx" \
  https://raw.githubusercontent.com/snakers4/silero-vad/master/src/silero_vad/data/silero_vad.onnx
cp "$REPO/models/silero_vad.onnx" Resources/

xcodegen generate --quiet
xcodebuild -project Interpreter.xcodeproj -scheme Interpreter -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$IOS/.build" \
  -allowProvisioningUpdates -skipMacroValidation -skipPackagePluginValidation -quiet build
APP="$IOS/.build/Build/Products/Release-iphoneos/Interpreter.app"
echo "built: $APP ($(du -sh "$APP" | cut -f1))"

[ "${1:-}" = "--no-install" ] && exit 0
DEVICE="$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /available/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) print $i}' | head -1)"
[ -n "$DEVICE" ] || { echo "no iPhone connected and available" >&2; exit 1; }
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" com.snepssen.interpreter >/dev/null && echo "launched on the iPhone"
