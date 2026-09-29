#!/bin/sh
# Links the PSDK core frameworks for one SDK: Psdk25Core, Psdk30Core,
# Psdk32Core and Psdk33Core.
#
# Each one is libpsdk<NN>.a from the PSDK core release that
# cores/psdk/.version pins, and psdk_app_bridge.cpp, which
# answers the launcher interface with the core's calls. The export list
# keeps the Ruby and every library of the core inside the framework.
#
# The script does nothing when the frameworks match the core pin, the
# ANGLE pin and the bridge files. Xcode runs it before each build.
#
# Usage:
#   cores/psdk/build-framework-ios.sh [--sdk iphoneos|iphonesimulator]
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPS="$ROOT/ios/Dependencies"
CORE="$DEPS/psdk-core"

# Xcode and a script can link at the same time. lockf runs one at a time,
# and the second then finds the frameworks in place.
if [ -z "${PSDK_FRAMEWORKS_LOCKED:-}" ]; then
    PSDK_FRAMEWORKS_LOCKED=1 exec lockf -k "$CORE.frameworks.lock" "$0" "$@"
fi

SDK=iphoneos
ARCH=arm64
MIN_OS=26.0
RUBIES="25 30 32 33"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --sdk)
            SDK="$2"
            shift 2
            ;;
        *)
            echo "build-framework-ios: unknown argument $1" >&2
            exit 2
            ;;
    esac
done

case "$SDK" in
    iphoneos)
        TARGET="${ARCH}-apple-ios${MIN_OS}"
        PLATFORM=iPhoneOS
        ;;
    iphonesimulator)
        TARGET="${ARCH}-apple-ios${MIN_OS}-simulator"
        PLATFORM=iPhoneSimulator
        ;;
    *)
        echo "build-framework-ios: unknown sdk $SDK" >&2
        exit 2
        ;;
esac

"$ROOT/tools/fetch-angle.sh"
"$ROOT/cores/psdk/fetch.sh"

TREE="$DEPS/build-$SDK-arm64"
ANGLE="$DEPS/ANGLE/$SDK"
SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CXX="$(xcrun --sdk "$SDK" -f clang++)"
CORE_VERSION="$(cut -d" " -f1 "$CORE/.fetched-pin")"

STAMP="$TREE/.psdk-frameworks"
WANT_STAMP="$(cat "$CORE/.fetched-pin" "$DEPS/ANGLE/.version" "$0" \
    "$ROOT/cores/psdk/psdk_app_bridge.cpp" "$ROOT/cores/GameCore.h" | shasum -a 256 | awk '{print $1}')"
BUILT=yes
for ruby in $RUBIES; do
    [ -f "$TREE/Psdk${ruby}Core.framework/Psdk${ruby}Core" ] || BUILT=no
done
if [ "$BUILT" = yes ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$WANT_STAMP" ]; then
    exit 0
fi

mkdir -p "$TREE/lib"
BRIDGE="$TREE/lib/psdk-bridge.o"
echo "[psdk-framework] Compiling the bridge..."
"$CXX" -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" -std=c++17 -O2 \
    -I"$ROOT/cores" -I"$CORE/include" -I"$ANGLE/include" \
    -c "$ROOT/cores/psdk/psdk_app_bridge.cpp" -o "$BRIDGE"

"$ROOT/cores/gamecore-exports.sh" "$TREE/gamecore.exports"

for ruby in $RUBIES; do
    NAME="Psdk${ruby}Core"
    FW="$TREE/$NAME.framework"
    rm -rf "$FW"
    mkdir -p "$FW"

    echo "[psdk-framework] Linking $NAME..."
    "$CXX" -dynamiclib -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" \
        -install_name "@rpath/$NAME.framework/$NAME" \
        -Wl,-exported_symbols_list,"$TREE/gamecore.exports" \
        -o "$FW/$NAME" \
        "$BRIDGE" "$CORE/$SDK/libpsdk$ruby.a" \
        -L"$ANGLE/lib" -lANGLE_static -lEGL_static -lGLESv2_static \
        -lz -lbz2 -liconv \
        -framework Foundation -framework UIKit -framework CoreFoundation \
        -framework CoreGraphics -framework CoreVideo -framework CoreAudio \
        -framework AudioToolbox -framework AVFoundation -framework Metal \
        -framework QuartzCore -framework GameController -framework CoreMotion \
        -framework IOSurface \
        -weak_framework CoreBluetooth -weak_framework CoreHaptics

    # The core prepends PsdkSupport to $LOAD_PATH and points GAMEDEPS at
    # it. psdk_app_bridge.cpp finds it next to the core binary with
    # dladdr.
    cp -R "$CORE/support/$(echo "$ruby" | sed 's/./&./')" "$FW/PsdkSupport"

    cat >"$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$NAME</string>
	<key>CFBundleIdentifier</key><string>sh.mateo.empo.psdk${ruby}core</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$NAME</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>$PLATFORM</string></array>
	<key>MinimumOSVersion</key><string>$MIN_OS</string>
	<key>EmpoCoreVersion</key><string>$CORE_VERSION</string>
</dict>
</plist>
PLIST

    "$ROOT/cores/psdk/check-framework.sh" --framework "$FW" --sdk "$SDK"
done
printf '%s\n' "$WANT_STAMP" >"$STAMP"
echo "[psdk-framework] Done"
