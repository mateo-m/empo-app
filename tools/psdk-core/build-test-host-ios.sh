#!/bin/sh
# Build PsdkTests.app, a minimal iOS host that runs one released Pokemon
# SDK game on the PSDK core.
#
# There is no Xcode project. An iOS app bundle is a directory with a
# Mach-O binary, an Info.plist and resources, so this script assembles
# one by hand. The same shape as the engine's
# mkxp-z-apple-mobile/tools/build-test-host-ios.sh.
#
# Usage:
#   tools/psdk-core/build-test-host-ios.sh [--out <dir>]
#
# Prerequisite:
#   cd ios/Dependencies && make -f iphonesimulator.make psdk
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/tools/psdk-core"
DEPS="$ROOT/ios/Dependencies"

SDK=iphonesimulator
ARCH=arm64
MIN_OS=26.0
OUT="$ROOT/build/psdk-core"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --out)
            OUT="$2"
            shift 2
            ;;
        *)
            echo "build-test-host-ios: unknown argument $1" >&2
            exit 2
            ;;
    esac
done

TREE="$DEPS/build-$SDK-$ARCH"
ANGLE="$DEPS/ANGLE/$SDK"

if [ ! -f "$TREE/lib/litergss30-merged.o" ]; then
    echo "build-test-host-ios: litergss30-merged.o missing." >&2
    echo "Run: cd ios/Dependencies && make -f $SDK.make psdk" >&2
    exit 1
fi

if [ ! -d "$TREE/psdk-support" ]; then
    echo "build-test-host-ios: psdk-support missing." >&2
    echo "Run: cd ios/Dependencies && make -f $SDK.make psdk" >&2
    exit 1
fi

APP="$OUT/PsdkTests.app"
OBJ="$OUT/obj"
SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CC="$(xcrun --sdk "$SDK" -f clang)"
# The core, LiteCGSS and SFML are C++, so the link driver has to be
# clang++. It brings in libc++ and the C++ ABI runtime.
CXX="$(xcrun --sdk "$SDK" -f clang++)"
TARGET="${ARCH}-apple-ios${MIN_OS}-simulator"

mkdir -p "$OBJ" "$APP"

echo "[psdk-host] Compiling the host..."
"$CC" -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" \
    -mios-simulator-version-min="$MIN_OS" \
    -fobjc-arc -O2 \
    -I"$DEPS/psdk" \
    -c "$HERE/host.m" -o "$OBJ/host.o"

echo "[psdk-host] Linking..."
"$CXX" -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" \
    -mios-simulator-version-min="$MIN_OS" \
    -L"$TREE/lib" -L"$ANGLE/lib" \
    -o "$APP/PsdkTests" \
    "$OBJ/host.o" \
    "$TREE/lib/litergss30-merged.o" \
    -lLiteCGSS_engine -lskalog \
    -lsfml-graphics-s -lsfml-window-s -lsfml-audio-s -lsfml-system-s \
    -lfreetype -lpng16 -logg -lvorbis -lvorbisfile -lvorbisenc -lFLAC \
    -lz -lbz2 -liconv \
    -lANGLE_static -lEGL_static -lGLESv2_static \
    -framework Foundation -framework UIKit -framework CoreFoundation \
    -framework CoreGraphics -framework CoreVideo -framework CoreAudio \
    -framework AudioToolbox -framework AVFoundation -framework Metal \
    -framework QuartzCore -framework GameController -framework CoreMotion \
    -framework IOSurface -framework OpenAL \
    -weak_framework CoreBluetooth -weak_framework CoreHaptics \
    -weak_framework OpenGLES

echo "[psdk-host] Assembling the bundle..."
cp "$HERE/Info.plist" "$APP/Info.plist"
cp "$HERE/prelude.rb" "$APP/prelude.rb"
# The core prepends this folder to $LOAD_PATH and points GAMEDEPS at it.
rm -rf "$APP/PsdkSupport"
cp -R "$TREE/psdk-support" "$APP/PsdkSupport"

# An unsigned bundle installs on some simulator runtimes and not on
# others. An ad-hoc signature works everywhere and needs no identity.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 ||
    echo "build-test-host-ios: warning: ad-hoc codesign failed" >&2

echo "[psdk-host] Done: $APP"
