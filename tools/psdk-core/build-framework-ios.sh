#!/bin/sh
# Link the PSDK core as one dynamic framework for one SDK.
#
# The framework is the artifact a launcher embeds, and its export list
# is what keeps the core's Ruby 3.0 and its LiteRGSS classes to itself.
# `ld -r -unexported_symbols_list`, which builds litergss30-merged.o,
# cannot do that: it leaves a tentative definition as "(common) private
# external" and a C++ vtable as "weak external automatically hidden",
# and both still merge with a definition of the same name at the final
# link. Today litergss30-merged.o shares 212 common symbols with
# mkxp31-merged.o, and its __ZTV15ViewportElement plus the two
# ViewportElement destructors lose to mkxp-z's strong definitions.
#
# The link line is the one in build-test-host-ios.sh, minus host.o, plus
# -dynamiclib and the export list. Keep the two in step.
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
FW="$TREE/PsdkCore.framework"
SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CXX="$(xcrun --sdk "$SDK" -f clang++)"

if [ ! -f "$TREE/lib/litergss30-merged.o" ]; then
    echo "build-framework-ios: litergss30-merged.o missing." >&2
    echo "Run: cd ios/Dependencies && make -f $SDK.make psdk" >&2
    exit 1
fi

if [ ! -d "$TREE/psdk-support" ]; then
    echo "build-framework-ios: psdk-support missing." >&2
    echo "Run: cd ios/Dependencies && make -f $SDK.make psdk" >&2
    exit 1
fi

if [ ! -f "$ANGLE/lib/libANGLE_static.a" ]; then
    echo "build-framework-ios: ANGLE missing. Run: tools/fetch-angle.sh" >&2
    exit 1
fi

rm -rf "$FW"
mkdir -p "$FW/Headers"
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

# Only the names this core really defines. psdk_app_bridge.h declares
# 102 and psdk_app_bridge.cpp answers the ones a launcher calls. A name
# in the list that no object defines makes the linker warn and the
# export list drift away from what the core can do.
nm -gU "$TREE/lib/litergss30-merged.o" |
    awk '/^[0-9a-f]+ [TDSR] /{print $3}' | sort -u >"$TREE/psdk-core.defined"
comm -12 "$TREE/psdk-core.exports.want" "$TREE/psdk-core.defined" \
    >"$TREE/psdk-core.exports"

echo "[psdk-framework] Linking..."
"$CXX" -dynamiclib -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" \
    -install_name "@rpath/PsdkCore.framework/PsdkCore" \
    -Wl,-exported_symbols_list,"$TREE/psdk-core.exports" \
    -L"$TREE/lib" -L"$ANGLE/lib" \
    -o "$FW/PsdkCore" \
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
    -framework IOSurface -lopenal \
    -weak_framework CoreBluetooth -weak_framework CoreHaptics \
    -weak_framework OpenGLES

echo "[psdk-framework] Assembling the bundle..."
cp "$DEPS/psdk/psdk_core.h" "$FW/Headers/"
# The core prepends this folder to $LOAD_PATH and points GAMEDEPS at it.
# It ships inside the framework so a launcher embeds one artifact.
rm -rf "$FW/PsdkSupport"
cp -R "$TREE/psdk-support" "$FW/PsdkSupport"

# Per-game compatibility code. psdk_app_bridge.cpp finds it next to the
# core binary with dladdr and hands the path to psdk_run.
cp "$DEPS/psdk/runtime_prelude.rb" "$FW/"

cat >"$FW/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>PsdkCore</string>
	<key>CFBundleIdentifier</key><string>sh.mateo.empo.psdkcore</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>PsdkCore</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>$PLATFORM</string></array>
	<key>MinimumOSVersion</key><string>$MIN_OS</string>
	<key>EmpoCoreRGSSVersionMask</key><integer>0</integer>
</dict>
</plist>
EOF

# The tree keeps the framework, and Xcode only copies it. Record which
# script wrote it, so check-psdk-framework.sh can fail when this file
# changed and nobody rebuilt the engine half.
shasum -a 256 "$ROOT/tools/psdk-core/build-framework-ios.sh" |
    awk '{print $1}' >"$FW/.build-script-sha256"

"$ROOT/scripts/check-psdk-framework.sh" --framework "$FW" --sdk "$SDK"
echo "[psdk-framework] Done: $FW"
