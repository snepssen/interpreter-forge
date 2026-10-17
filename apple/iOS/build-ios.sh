#!/usr/bin/env bash
# Build the iPhone and iPad app and install it on a connected device.
#
#   iOS/build-ios.sh                # build, install on the first connected iPhone or iPad
#   iOS/build-ios.sh --device iPad  # on the first connected iPad (or a name, like "iPhone 17")
#   iOS/build-ios.sh --no-install
#
# The voice is voice-polyglot's newest export or release
# (scripts/polyglot-voice.sh); espeak-ng and its data come with the voice-core
# package, in its resource bundle; the VAD model from models/. The translation model is not bundled: the app fetches
# it on first launch (2.3 GB, best on Wi-Fi).
set -euo pipefail
cd "$(dirname "$0")"
IOS="$(pwd)"
REPO="$(cd ../.. && pwd)"
VOICE="$("$IOS/../scripts/polyglot-voice.sh")"

mkdir -p Resources
rm -f Resources/en_US-snepssen-medium.onnx Resources/en_US-snepssen-medium.onnx.json
cp "$VOICE" Resources/snepssen-polyglot.onnx
cp "$VOICE.json" Resources/snepssen-polyglot.onnx.json
echo "voice: $VOICE"
rm -rf Resources/espeak-ng-data  # now voice-core's, in its resource bundle
[ -s "$REPO/models/silero_vad.onnx" ] || curl -fsSL -o "$REPO/models/silero_vad.onnx" \
  https://raw.githubusercontent.com/snakers4/silero-vad/master/src/silero_vad/data/silero_vad.onnx
cp "$REPO/models/silero_vad.onnx" Resources/

xcodegen generate --quiet
# Remove only the generated app, retaining dependency/build caches. A successful
# no-op must never leave an old bundle available for installation.
APP="$IOS/.build/Build/Products/Release-iphoneos/Interpreter.app"
rm -rf "$APP"
build_app() {
  xcodebuild -project Interpreter.xcodeproj -scheme InterpreterPhone -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$IOS/.build" \
    -allowProvisioningUpdates -skipMacroValidation -skipPackagePluginValidation "$@"
}
build_app build
if [ ! -d "$APP" ]; then
  echo "Xcode produced no app; clearing stale build products and rebuilding once" >&2
  build_app clean build
fi
[ -d "$APP" ] || { echo "build produced no app; refusing to install" >&2; exit 1; }
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
[ "$BUNDLE_ID" = "com.snepssen.interpreter" ] && [ -s "$APP/$EXECUTABLE" ] || {
  echo "build produced an invalid app; refusing to install" >&2; exit 1;
}
[ -s "$APP/VoiceCore_VoiceCore.bundle/espeak-ng-data/phontab" ] \
  || { echo "error: voice-core's espeak-ng data is missing from the app" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
echo "built: $APP ($(du -sh "$APP" | cut -f1))"

[ "${1:-}" = "--no-install" ] && exit 0
WANT="iPhone|iPad"
[ "${1:-}" = "--device" ] && WANT="${2:?a device, like iPad or \"iPhone 17\"}"
LINE="$(xcrun devicectl list devices 2>/dev/null | grep -E "$WANT" | grep -E "available|connected" | head -1 || true)"
DEVICE="$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) print $i}' <<< "$LINE" | head -1)"
[ -n "$DEVICE" ] || {
  echo "no $WANT connected and available. A new device needs unlocking, 'Trust This Computer', and" >&2
  echo "Developer Mode on (Settings → Privacy & Security → Developer Mode); see: xcrun devicectl list devices" >&2
  exit 1
}
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --terminate-existing --device "$DEVICE" com.snepssen.interpreter >/dev/null \
  && echo "launched on $(awk '{print $1, $2}' <<< "$LINE" | sed 's/  *$//')"
