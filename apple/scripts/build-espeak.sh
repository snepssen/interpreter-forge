#!/usr/bin/env bash
# espeak-ng as an XCFramework for macOS, iOS and the iOS simulator.
#
# The same commit and options as piper1-gpl's CMakeLists.txt (the build
# voice-forge's macOS library came from: it reports 1.52.0.1), so the phonemes
# a voice was trained on are the phonemes it is given. Only the library and
# ucd are built: compiling the dictionaries runs the freshly built binary,
# which a cross-compile for iOS cannot; the data comes from voice-forge.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
COMMIT=724808c
WORK="$ROOT/.build/espeak"
OUT="$ROOT/Frameworks/CEspeakNG.xcframework"

[ -d "$WORK/src" ] || git clone -q https://github.com/espeak-ng/espeak-ng.git "$WORK/src"
git -C "$WORK/src" checkout -q "$COMMIT"
UCD="$WORK/src/src/ucd-tools/src/include"

build() {  # name, extra cmake args...
  local name=$1; shift
  local dir="$WORK/build-$name"
  cmake -S "$WORK/src" -B "$dir" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DUSE_ASYNC=OFF -DUSE_MBROLA=OFF -DUSE_LIBSONIC=OFF -DUSE_LIBPCAUDIO=OFF \
    -DUSE_KLATT=OFF -DUSE_SPEECHPLAYER=OFF -DEXTRA_cmn=ON -DEXTRA_ru=ON \
    -DCOMPILE_INTONATIONS=OFF -DENABLE_TESTS=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 \
    "-DCMAKE_C_FLAGS=-D_FILE_OFFSET_BITS=64 -I$UCD" "-DCMAKE_CXX_FLAGS=-D_FILE_OFFSET_BITS=64 -I$UCD" \
    "$@" >/dev/null
  cmake --build "$dir" --target espeak-ng ucd -j 8 >/dev/null
  mkdir -p "$WORK/out/$name"
  libtool -static -o "$WORK/out/$name/libCEspeakNG.a" \
    "$(find "$dir" -name 'libespeak-ng.a' | head -1)" "$(find "$dir" -name 'libucd.a' | head -1)"
  echo "built $name: $(lipo -archs "$WORK/out/$name/libCEspeakNG.a")"
}

build macos -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
build ios -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_MACOSX_BUNDLE=OFF -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0
build ios-simulator -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_MACOSX_BUNDLE=OFF -DCMAKE_OSX_SYSROOT=iphonesimulator -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0

HEADERS="$WORK/headers"
rm -rf "$HEADERS" && mkdir -p "$HEADERS/espeak-ng"
cp "$WORK/src/src/include/espeak-ng/"{speak_lib.h,espeak_ng.h,encoding.h} "$HEADERS/espeak-ng/"
cat > "$HEADERS/module.modulemap" <<'MAP'
module CEspeakNG {
    header "espeak-ng/speak_lib.h"
    header "espeak-ng/espeak_ng.h"
    header "espeak-ng/encoding.h"
    link "c++"
    export *
}
MAP

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$WORK/out/macos/libCEspeakNG.a" -headers "$HEADERS" \
  -library "$WORK/out/ios/libCEspeakNG.a" -headers "$HEADERS" \
  -library "$WORK/out/ios-simulator/libCEspeakNG.a" -headers "$HEADERS" \
  -output "$OUT" >/dev/null
echo "wrote $OUT ($(du -sh "$OUT" | cut -f1))"
