#!/bin/sh
# Build MkxpTests.app, a minimal iOS host that runs one RPG Maker game
# on the mkxp-z core.
#
# There is no Xcode project. An iOS app bundle is a directory with a
# Mach-O binary, an Info.plist and resources, so this script assembles
# one by hand. The same shape as tools/psdk-core/build-test-host-ios.sh.
#
# Usage:
#   tools/mkxp-core/build-test-host-ios.sh [--out <dir>]
#
# Prerequisite:
#   tools/mkxp-core/build-framework-ios.sh --sdk iphonesimulator
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/tools/mkxp-core"
DEPS="$ROOT/ios/Dependencies"

SDK=iphonesimulator
ARCH=arm64
MIN_OS=26.0
OUT="$ROOT/build/mkxp-core"

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

if [ ! -d "$TREE/MkxpCore.framework" ]; then
    echo "build-test-host-ios: MkxpCore.framework missing." >&2
    echo "Run: tools/mkxp-core/build-framework-ios.sh --sdk $SDK" >&2
    exit 1
fi

APP="$OUT/MkxpTests.app"
OBJ="$OUT/obj"
SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CC="$(xcrun --sdk "$SDK" -f clang)"
TARGET="${ARCH}-apple-ios${MIN_OS}-simulator"

mkdir -p "$OBJ" "$APP"

echo "[mkxp-host] Compiling the host..."
"$CC" -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" \
    -mios-simulator-version-min="$MIN_OS" \
    -fobjc-arc -O2 \
    -c "$HERE/host.m" -o "$OBJ/host.o"

echo "[mkxp-host] Linking..."
# The host does not link the core. It opens the framework with dlopen at
# run time, so nothing here names MkxpCore.
"$CC" -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" \
    -mios-simulator-version-min="$MIN_OS" \
    -o "$APP/MkxpTests" \
    "$OBJ/host.o" \
    -framework Foundation -framework UIKit

echo "[mkxp-host] Assembling the bundle..."
cp "$HERE/Info.plist" "$APP/Info.plist"
rm -rf "$APP/Frameworks"
mkdir -p "$APP/Frameworks"
cp -R "$TREE/MkxpCore.framework" "$APP/Frameworks/"

# An unsigned bundle installs on some simulator runtimes and not on
# others. An ad-hoc signature works everywhere and needs no identity.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 ||
    echo "build-test-host-ios: warning: ad-hoc codesign failed" >&2

echo "[mkxp-host] Done: $APP"
