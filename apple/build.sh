#!/usr/bin/env bash
# Build Interpreter.app.
#
# xcodebuild rather than `swift build`: MLX compiles Metal shaders, which only
# Xcode's build system does. The voice is voice-polyglot's newest export
# (scripts/polyglot-voice.sh) and espeak-ng data comes from voice-forge, both
# beside this checkout; the translation model
# (2.3 GB) is not bundled, and is found in ~/Library/Application Support/
# Interpreter/Models or in this checkout's models/ (scripts/fetch-models.sh).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
REPO="$(dirname "$ROOT")"
VOICEFORGE="$(dirname "$REPO")/voice-forge/macos/Sources/VoiceForgeTTS/Resources"
APP="$ROOT/Interpreter.app"
CONF="${1:-Release}"
DERIVED="$ROOT/.build/xcode"
PRODUCTS="$DERIVED/Build/Products/$CONF"
VOICE="$("$ROOT/scripts/polyglot-voice.sh")"

echo "checks…"
swift run -q tccheck

echo "building ($CONF)…"
for scheme in Interpreter tcrun; do
  rm -f "$PRODUCTS/$scheme"
  xcodebuild -scheme "$scheme" -configuration "$CONF" -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED" -skipMacroValidation -skipPackagePluginValidation -quiet build
  [ -s "$PRODUCTS/$scheme" ] && [ -x "$PRODUCTS/$scheme" ] || {
    echo "error: build produced no $scheme executable; refusing to package" >&2; exit 1;
  }
done

[ -d "$VOICEFORGE/espeak-ng-data" ] || { echo "error: no espeak-ng-data in $VOICEFORGE" >&2; exit 1; }
VAD="$REPO/models/silero_vad.onnx"
if [ ! -s "$VAD" ]; then
  mkdir -p "$REPO/models"
  curl -fsSL -o "$VAD" https://raw.githubusercontent.com/snakers4/silero-vad/master/src/silero_vad/data/silero_vad.onnx
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/Interpreter" "$APP/Contents/MacOS/Interpreter"

# SwiftPM resource bundles (MLX's Metal library among them) belong in
# Contents/Resources, where Bundle.module looks.
bundles=0
while IFS= read -r b; do
  cp -R "$b" "$APP/Contents/Resources/"
  bundles=$((bundles + 1))
done < <(find "$PRODUCTS" -maxdepth 1 -name '*.bundle')
[ -n "$(find "$APP/Contents/Resources" -name default.metallib)" ] || { echo "error: MLX's Metal library is missing" >&2; exit 1; }

cp "$VOICE" "$APP/Contents/Resources/snepssen-polyglot.onnx"
cp "$VOICE.json" "$APP/Contents/Resources/snepssen-polyglot.onnx.json"
echo "voice: $VOICE"
cp -R "$VOICEFORGE/espeak-ng-data" "$APP/Contents/Resources/"
cp "$VAD" "$APP/Contents/Resources/"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"  # scripts/make-icon.py

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Interpreter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>local.translate-core.interpreter</string>
  <key>CFBundleName</key><string>Interpreter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Interpreter listens to the conversation around you to translate it into English, on this Mac.</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
echo "built: $APP  ($CONF, $bundles resource bundles, $(du -sh "$APP" | cut -f1))"
