#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

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
#   cores/psdk/build-framework-ios.sh [--sdk iphoneos|iphonesimulator|macosx]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPS="$ROOT/ios/Dependencies"
CORE="$DEPS/psdk-core"
# shellcheck source=cores/framework-common.sh
. "$ROOT/cores/framework-common.sh"
# shellcheck source=cores/cores.sh
. "$ROOT/cores/cores.sh"
read -ra RUBIES <<<"$(psdk_rubies)"

run_locked "$CORE.frameworks.lock" "$0" "$@"
parse_sdk "$@"

"$ROOT/tools/fetch-angle.sh"
"$ROOT/cores/psdk/fetch.sh"

TREE="$DEPS/build-$SDK-$ARCH"
ANGLE="$DEPS/ANGLE/$SDK"
SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CXX="$(xcrun --sdk "$SDK" -f clang++)"
CORE_VERSION="$(cut -d" " -f1 "$CORE/.fetched-pin")"

STAMP="$TREE/.psdk-frameworks"
WANT_STAMP="$( (echo "$MIN_OS" && cat "$CORE/.fetched-pin" "$DEPS/ANGLE/.version" "$0" \
    "$ROOT/cores/framework-common.sh" "$ROOT/cores/psdk/psdk_app_bridge.cpp" "$ROOT/cores/GameCore.h" "$ROOT/cores/gamecore.exports" "$ROOT/cores/PrivacyInfo.xcprivacy") | shasum -a 256 | awk '{print $1}')"
BUILT=yes
for ruby in "${RUBIES[@]}"; do
    [ -f "$TREE/Psdk${ruby}Core.framework/Psdk${ruby}Core" ] || BUILT=no
done
if [ "$BUILT" = yes ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$WANT_STAMP" ]; then
    exit 0
fi

mkdir -p "$TREE/lib"
BRIDGE="$TREE/lib/psdk-bridge.o"
echo "[psdk-framework] Compiling the bridge..."
# On macOS the core draws with the system OpenGL, and the bridge pumps
# AppKit events while the game is paused.
if [ "$SDK" = macosx ]; then
    BRIDGE_FLAGS=(-x objective-c++ -fobjc-arc)
else
    BRIDGE_FLAGS=("-I$ANGLE/include")
fi
"$CXX" -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" -std=c++17 -O2 "${BRIDGE_FLAGS[@]}" \
    -I"$ROOT/cores" -I"$CORE/include" \
    -c "$ROOT/cores/psdk/psdk_app_bridge.cpp" -o "$BRIDGE"

# The frameworks differ between iOS and macOS. The macOS core has no
# ANGLE, because SFML uses the system OpenGL there. SFML's Cocoa backend
# keeps methods in Objective-C categories, and the linker drops a
# category from a static library without -ObjC. SFOpenGLView then
# raises "unrecognized selector" when the game makes its window.
if [ "$SDK" = macosx ]; then
    LIBS=(-ObjC -framework Foundation -framework AppKit -framework Carbon -framework IOKit
        -framework OpenGL -framework CoreFoundation -framework CoreGraphics
        -framework CoreAudio -framework AudioToolbox -framework AudioUnit
        -framework CoreServices -framework Security -lz -lbz2 -liconv)
else
    LIBS=("-L$ANGLE/lib" -lANGLE_static -lEGL_static -lGLESv2_static
        -lz -lbz2 -liconv
        -framework Foundation -framework UIKit -framework CoreFoundation
        -framework CoreGraphics -framework CoreVideo -framework CoreAudio
        -framework AudioToolbox -framework AVFoundation -framework Metal
        -framework QuartzCore -framework GameController -framework CoreMotion
        -framework IOSurface
        -weak_framework CoreBluetooth -weak_framework CoreHaptics)
fi

for ruby in "${RUBIES[@]}"; do
    NAME="Psdk${ruby}Core"
    FW="$TREE/$NAME.framework"
    start_framework "$FW"

    echo "[psdk-framework] Linking $NAME..."
    "$CXX" -dynamiclib -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" \
        -install_name "@rpath/$NAME.framework/$NAME" \
        -Wl,-exported_symbols_list,"$ROOT/cores/gamecore.exports" \
        -o "$BIN_DIR/$NAME" \
        "$BRIDGE" "$CORE/$SDK/libpsdk$ruby.a" "${LIBS[@]}"

    # The core prepends PsdkSupport to $LOAD_PATH and points GAMEDEPS at
    # it. psdk_app_bridge.cpp finds it in the resources of the
    # framework bundle.
    cp -R "$CORE/support/${ruby:0:1}.${ruby:1}" "$RES/PsdkSupport"

    finish_framework "$FW" "$NAME" "sh.mateo.empo.psdk${ruby}core" "$CORE_VERSION" "$CORE/licenses.json"

    "$ROOT/cores/psdk/check-framework.sh" --framework "$FW" --sdk "$SDK"
done
printf '%s\n' "$WANT_STAMP" >"$STAMP"
echo "[psdk-framework] Done"
