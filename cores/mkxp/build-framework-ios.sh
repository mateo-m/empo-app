#!/bin/sh
# Links MkxpCore.framework for one SDK from the engine release that
# cores/mkxp/.version pins.
#
# The release gives the libraries and a LINK file with the linker
# flags. mkxp_app_bridge.c answers GameCore.h with the engine's mkxp_
# functions. The export list keeps the three Ruby VMs, SDL and the
# mkxp_ names inside the framework: only the gamecore_ names leave it.
#
# The script does nothing when the framework matches the engine pin, the
# ANGLE pin, the bridge and this script. Xcode runs it before each build.
#
# Usage:
#   cores/mkxp/build-framework-ios.sh [--sdk iphoneos|iphonesimulator]
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPS="$ROOT/ios/Dependencies"
CORE="$DEPS/mkxp-core"

# Xcode and a script can link at the same time. lockf runs one at a time,
# and the second then finds the framework in place.
if [ -z "${MKXP_FRAMEWORK_LOCKED:-}" ]; then
    MKXP_FRAMEWORK_LOCKED=1 exec lockf -k "$CORE.framework.lock" "$0" "$@"
fi

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

"$ROOT/tools/fetch-angle.sh"
"$ROOT/cores/mkxp/fetch.sh"

TREE="$DEPS/build-$SDK-$ARCH"
ANGLE="$DEPS/ANGLE/$SDK"
FW="$TREE/MkxpCore.framework"
SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CC="$(xcrun --sdk "$SDK" -f clang)"
CXX="$(xcrun --sdk "$SDK" -f clang++)"
CORE_VERSION="$(cut -d" " -f1 "$CORE/.fetched-pin")"
RGSS_MASK="$(sed -n 's/^rgss_mask=//p' "$CORE/MANIFEST")"

# The engine compiles against the ANGLE headers of its own release, so
# the app must link the same one.
CORE_ANGLE="$(sed -n 's/^angle=//p' "$CORE/MANIFEST")"
APP_ANGLE="$(sed -n 's/^ANGLE_VERSION=//p' "$DEPS/ANGLE/.version")"
if [ "$CORE_ANGLE" != "$APP_ANGLE" ]; then
    echo "error: the engine $CORE_VERSION needs ANGLE $CORE_ANGLE, but ios/Dependencies/ANGLE/.version pins $APP_ANGLE" >&2
    exit 1
fi

STAMP="$TREE/.mkxp-framework"
WANT_STAMP="$(cat "$CORE/.fetched-pin" "$DEPS/ANGLE/.version" "$0" \
    "$ROOT/cores/mkxp/mkxp_app_bridge.c" "$ROOT/cores/GameCore.h" | shasum -a 256 | awk '{print $1}')"
if [ -f "$FW/MkxpCore" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$WANT_STAMP" ]; then
    exit 0
fi

rm -rf "$FW"
mkdir -p "$FW" "$TREE/lib"

BRIDGE="$TREE/lib/mkxp-bridge.o"
"$CC" -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" -std=c11 -O2 -Wall -Werror \
    -I"$ROOT/cores" -I"$CORE/include" \
    -c "$ROOT/cores/mkxp/mkxp_app_bridge.c" -o "$BRIDGE"
"$ROOT/cores/gamecore-exports.sh" "$TREE/gamecore.exports"

echo "[mkxp-framework] Linking $CORE_VERSION..."
# LINK names its files relative to <sdk>/.
# shellcheck disable=SC2046
(cd "$CORE/$SDK" && "$CXX" -dynamiclib -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" \
    -install_name "@rpath/MkxpCore.framework/MkxpCore" \
    -Wl,-exported_symbols_list,"$TREE/gamecore.exports" \
    -L"$ANGLE/lib" \
    -o "$FW/MkxpCore" \
    "$BRIDGE" $(cat "$CORE/LINK"))

# The engine reads its assets and the Ruby stdlib through its own
# bundle, which dladdr resolves to this framework (filesystemImplIOS.mm).
cp -R "$CORE/assets" "$FW/Assets.bundle"
cp -R "$CORE/$SDK/ruby-stdlib" "$FW/Ruby"

# GameImportValidator reads EmpoCoreRGSSVersionMask at import, before
# any core is open.
cat >"$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>MkxpCore</string>
	<key>CFBundleIdentifier</key><string>sh.mateo.empo.mkxpcore</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>MkxpCore</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>$PLATFORM</string></array>
	<key>MinimumOSVersion</key><string>$MIN_OS</string>
	<key>EmpoCoreRGSSVersionMask</key><integer>$RGSS_MASK</integer>
	<key>EmpoCoreVersion</key><string>$CORE_VERSION</string>
</dict>
</plist>
PLIST

"$ROOT/cores/mkxp/check-framework.sh" --framework "$FW" --sdk "$SDK"
printf '%s\n' "$WANT_STAMP" >"$STAMP"
echo "[mkxp-framework] Done: $FW"
