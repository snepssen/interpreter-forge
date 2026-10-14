#!/usr/bin/env bash
# Build the iPhone app and install it on a connected iPhone.
#
#   iOS/build-ios.sh            # build, install on the first connected iPhone
#   iOS/build-ios.sh --no-install
#
# The voice is voice-polyglot's newest export (scripts/polyglot-voice.sh) and
# espeak-ng data comes from voice-forge, both beside translate-core; the
# VAD model from models/. The translation model is not bundled: the app fetches
# it on first launch (2.3 GB, best on Wi-Fi).
set -euo pipefail
cd "$(dirname "$0")"
IOS="$(pwd)"
REPO="$(cd ../.. && pwd)"
VOICEFORGE="$(dirname "$REPO")/voice-forge/macos/Sources/VoiceForgeTTS/Resources"
VOICE="$("$IOS/../scripts/polyglot-voice.sh")"

mkdir -p Resources
rm -f Resources/en_US-snepssen-medium.onnx Resources/en_US-snepssen-medium.onnx.json
cp "$VOICE" Resources/snepssen-polyglot.onnx
cp "$VOICE.json" Resources/snepssen-polyglot.onnx.json
echo "voice: $VOICE"
rsync -a --delete "$VOICEFORGE/espeak-ng-data/" Resources/espeak-ng-data/
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
codesign --verify --deep --strict "$APP"
echo "built: $APP ($(du -sh "$APP" | cut -f1))"

[ "${1:-}" = "--no-install" ] && exit 0
DEVICE="$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /available/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-/) print $i}' | head -1)"
[ -n "$DEVICE" ] || { echo "no iPhone connected and available" >&2; exit 1; }
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --terminate-existing --device "$DEVICE" com.snepssen.interpreter >/dev/null && echo "launched on the iPhone"
