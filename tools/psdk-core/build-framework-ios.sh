#!/bin/sh
# Links the PSDK core frameworks for one SDK: Psdk25Core, Psdk30Core,
# Psdk32Core and Psdk33Core.
#
# Each one is libpsdk<NN>.a from the PSDK core release that
# ios/Dependencies/psdk/.version pins, and psdk_app_bridge.cpp, which
# answers the launcher interface with the core's calls. The export list
# keeps the Ruby and every library of the core inside the framework.
#
# The script does nothing when the frameworks match the core pin, the
# ANGLE pin and the bridge files. Xcode runs it before each build.
#
# Usage:
#   tools/psdk-core/build-framework-ios.sh [--sdk iphoneos|iphonesimulator]
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPS="$ROOT/ios/Dependencies"
CORE="$DEPS/psdk-core"

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
"$ROOT/tools/fetch-psdk-core.sh"

TREE="$DEPS/build-$SDK-arm64"
ANGLE="$DEPS/ANGLE/$SDK"
SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CXX="$(xcrun --sdk "$SDK" -f clang++)"
CORE_VERSION="$(cut -d" " -f1 "$CORE/.fetched-pin")"

STAMP="$TREE/.psdk-frameworks"
WANT_STAMP="$(cat "$CORE/.fetched-pin" "$DEPS/ANGLE/.version" "$0" \
    "$DEPS/psdk/psdk_app_bridge.cpp" "$DEPS/psdk/psdk_app_bridge.h" | shasum -a 256 | awk '{print $1}')"
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
    -I"$CORE/include" -I"$ANGLE/include" \
    -c "$DEPS/psdk/psdk_app_bridge.cpp" -o "$BRIDGE"

grep -oE '\bpsdk_[A-Za-z0-9_]+\(' "$DEPS/psdk/psdk_app_bridge.h" |
    sed 's/(//' | sed 's/^/_/' | sort -u >"$TREE/psdk-core.exports"

for ruby in $RUBIES; do
    NAME="Psdk${ruby}Core"
    FW="$TREE/$NAME.framework"
    rm -rf "$FW"
    mkdir -p "$FW"

    echo "[psdk-framework] Linking $NAME..."
    "$CXX" -dynamiclib -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" \
        -install_name "@rpath/$NAME.framework/$NAME" \
        -Wl,-exported_symbols_list,"$TREE/psdk-core.exports" \
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

    "$ROOT/scripts/check-psdk-framework.sh" --framework "$FW" --sdk "$SDK"
done
printf '%s\n' "$WANT_STAMP" >"$STAMP"
echo "[psdk-framework] Done"
