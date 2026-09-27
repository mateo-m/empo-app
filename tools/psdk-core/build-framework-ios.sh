#!/bin/sh
# Link the PSDK cores as dynamic frameworks for one SDK.
#
# A framework is the artifact a launcher embeds, and its export list is
# what keeps the core's Ruby and its LiteRGSS classes to itself. There
# is one for each Ruby: Psdk25Core, Psdk30Core, Psdk32Core and
# Psdk33Core. Each links litergss<NN>-merged.o, which exports only its
# _psdk_ruby_<NN> entry, and psdk-bridge<NN>.o, which calls it.
#
# Usage:
#   tools/psdk-core/build-framework-ios.sh [--sdk iphoneos|iphonesimulator]
#
# Prerequisites:
#   cd ios/Dependencies && make -f <sdk>.make psdk
#   tools/fetch-angle.sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPS="$ROOT/ios/Dependencies"

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

TREE="$DEPS/build-$SDK-$ARCH"
ANGLE="$DEPS/ANGLE/$SDK"
SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CXX="$(xcrun --sdk "$SDK" -f clang++)"

if [ ! -f "$ANGLE/lib/libANGLE_static.a" ]; then
    echo "build-framework-ios: ANGLE missing. Run: tools/fetch-angle.sh" >&2
    exit 1
fi

# The LiteRGSS2 source the cores were linked from. Empo's Game cores
# screen shows it.
#
# A copy of the source without .git makes git walk up to the top repo
# and answer with Empo's own tag, so ask for the gitlink in that case.
LITERGSS="$DEPS/sources/litergss2"
if [ -e "$LITERGSS/.git" ]; then
    CORE_VERSION="$(git -C "$LITERGSS" describe --tags --always --dirty 2>/dev/null || true)"
else
    CORE_VERSION="$(git -C "$ROOT" rev-parse --short HEAD:ios/Dependencies/sources/litergss2 2>/dev/null || true)"
fi
[ -n "$CORE_VERSION" ] || CORE_VERSION=unknown

# Two groups go out. psdk_run and psdk_inject_scancode, which
# psdk_core.h declares for a host that drives the core directly (the
# test host does). The launcher interface, which psdk_app_bridge.h
# declares, and which a launcher resolves name by name in the core it
# opened.
{
    printf '_psdk_run\n_psdk_inject_scancode\n'
    grep -oE '\bpsdk_[A-Za-z0-9_]+\(' "$DEPS/psdk/psdk_app_bridge.h" |
        sed 's/(//' | sort -u | sed 's/^/_/'
} | sort -u >"$TREE/psdk-core.exports.want"

for ruby in $RUBIES; do
    NAME="Psdk${ruby}Core"
    OBJECT="$TREE/lib/litergss$ruby-merged.o"
    BRIDGE="$TREE/lib/psdk-bridge$ruby.o"
    SUPPORT="$TREE/psdk-support/$(echo "$ruby" | sed 's/./&./')"
    FW="$TREE/$NAME.framework"
    for part in "$OBJECT" "$BRIDGE" "$SUPPORT"; do
        if [ ! -e "$part" ]; then
            echo "build-framework-ios: $part missing." >&2
            echo "Run: cd ios/Dependencies && make -f $SDK.make psdk" >&2
            exit 1
        fi
    done

    rm -rf "$FW"
    mkdir -p "$FW/Headers"

    # Only the names this core really defines. psdk_app_bridge.h declares
    # 102 and psdk_app_bridge.cpp answers the ones a launcher calls. A
    # name in the list that no object defines makes the linker warn and
    # the export list drift away from what the core can do.
    nm -gU "$BRIDGE" |
        awk '/^[0-9a-f]+ [TDSR] /{print $3}' | sort -u >"$TREE/psdk-core.defined"
    comm -12 "$TREE/psdk-core.exports.want" "$TREE/psdk-core.defined" \
        >"$TREE/psdk-core.exports"

    echo "[psdk-framework] Linking $NAME..."
    "$CXX" -dynamiclib -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" \
        -install_name "@rpath/$NAME.framework/$NAME" \
        -Wl,-exported_symbols_list,"$TREE/psdk-core.exports" \
        -L"$TREE/lib" -L"$ANGLE/lib" \
        -o "$FW/$NAME" \
        "$OBJECT" "$BRIDGE" \
        -lLiteCGSS_engine -lskalog \
        -lsfml-graphics-s -lsfml-window-s -lsfml-audio-s -lsfml-system-s \
        -lfreetype -lpng16 -logg -lvorbis -lvorbisfile -lvorbisenc -lFLAC \
        -lssl -lcrypto -lz -lbz2 -liconv \
        -lANGLE_static -lEGL_static -lGLESv2_static \
        -framework Foundation -framework UIKit -framework CoreFoundation \
        -framework CoreGraphics -framework CoreVideo -framework CoreAudio \
        -framework AudioToolbox -framework AVFoundation -framework Metal \
        -framework QuartzCore -framework GameController -framework CoreMotion \
        -framework IOSurface -lopenal \
        -weak_framework CoreBluetooth -weak_framework CoreHaptics

    echo "[psdk-framework] Assembling $NAME..."
    cp "$DEPS/psdk/psdk_core.h" "$FW/Headers/"
    # The core prepends PsdkSupport to $LOAD_PATH and points GAMEDEPS at
    # it. It ships inside the framework so a launcher embeds one artifact.
    cp -R "$SUPPORT" "$FW/PsdkSupport"

    # Per-game compatibility code. psdk_app_bridge.cpp finds it next to
    # the core binary with dladdr and hands the path to psdk_run.
    cp "$DEPS/psdk/runtime_prelude.rb" "$FW/"

    cat >"$FW/Info.plist" <<EOF
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
EOF

    # The tree keeps the framework, and Xcode only copies it. Record which
    # script wrote it, so check-psdk-framework.sh can fail when this file
    # changed and nobody rebuilt the engine half.
    shasum -a 256 "$ROOT/tools/psdk-core/build-framework-ios.sh" |
        awk '{print $1}' >"$FW/.build-script-sha256"

    "$ROOT/scripts/check-psdk-framework.sh" --framework "$FW" --sdk "$SDK"
done
echo "[psdk-framework] Done"
