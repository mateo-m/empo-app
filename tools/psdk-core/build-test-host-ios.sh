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
#   tools/psdk-core/build-framework-ios.sh --sdk iphonesimulator
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

if [ ! -d "$TREE/PsdkCore.framework" ]; then
    echo "build-test-host-ios: PsdkCore.framework missing." >&2
    echo "Run: cd ios/Dependencies && make -f $SDK.make psdk" >&2
    exit 1
fi

APP="$OUT/PsdkTests.app"
OBJ="$OUT/obj"
SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CC="$(xcrun --sdk "$SDK" -f clang)"
TARGET="${ARCH}-apple-ios${MIN_OS}-simulator"

mkdir -p "$OBJ" "$APP"

echo "[psdk-host] Compiling the host..."
"$CC" -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" \
    -mios-simulator-version-min="$MIN_OS" \
    -fobjc-arc -O2 \
    -I"$DEPS/psdk" \
    -c "$HERE/host.m" -o "$OBJ/host.o"

echo "[psdk-host] Linking..."
# The host does not link the core. It opens the framework with dlopen at
# run time, so nothing here names PsdkCore.
"$CC" -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" \
    -mios-simulator-version-min="$MIN_OS" \
    -o "$APP/PsdkTests" \
    "$OBJ/host.o" \
    -framework Foundation -framework UIKit

echo "[psdk-host] Assembling the bundle..."
cp "$HERE/Info.plist" "$APP/Info.plist"
cp "$HERE/prelude.rb" "$APP/prelude.rb"
rm -rf "$APP/Frameworks"
mkdir -p "$APP/Frameworks"
cp -R "$TREE/PsdkCore.framework" "$APP/Frameworks/"

# An unsigned bundle installs on some simulator runtimes and not on
# others. An ad-hoc signature works everywhere and needs no identity.
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 ||
    echo "build-test-host-ios: warning: ad-hoc codesign failed" >&2

echo "[psdk-host] Done: $APP"
