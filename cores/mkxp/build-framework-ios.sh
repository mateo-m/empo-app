#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

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
#   cores/mkxp/build-framework-ios.sh [--sdk iphoneos|iphonesimulator|macosx]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPS="$ROOT/ios/Dependencies"
CORE="$DEPS/mkxp-core"
# shellcheck source=cores/framework-common.sh
. "$ROOT/cores/framework-common.sh"

run_locked "$CORE.framework.lock" "$0" "$@"
parse_sdk "$@"

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
WANT_STAMP="$( (echo "$MIN_OS" && cat "$CORE/.fetched-pin" "$DEPS/ANGLE/.version" "$0" \
    "$ROOT/cores/framework-common.sh" "$ROOT/cores/mkxp/mkxp_app_bridge.c" "$ROOT/cores/GameCore.h" "$ROOT/cores/PrivacyInfo.xcprivacy") | shasum -a 256 | awk '{print $1}')"
if [ -f "$FW/MkxpCore" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$WANT_STAMP" ]; then
    exit 0
fi

start_framework "$FW"
mkdir -p "$TREE/lib"

BRIDGE="$TREE/lib/mkxp-bridge.o"
"$CC" -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" -std=c11 -O2 -Wall -Werror \
    -I"$ROOT/cores" -I"$CORE/include" \
    -c "$ROOT/cores/mkxp/mkxp_app_bridge.c" -o "$BRIDGE"
"$ROOT/cores/gamecore-exports.sh" "$TREE/gamecore.exports"

echo "[mkxp-framework] Linking $CORE_VERSION..."
# LINK names its files relative to <sdk>/. The frameworks differ between
# iOS and macOS, so a macOS release has its own <sdk>/LINK.
LINK="$CORE/$SDK/LINK"
[ -f "$LINK" ] || LINK="$CORE/LINK"
# shellcheck disable=SC2046
(cd "$CORE/$SDK" && "$CXX" -dynamiclib -isysroot "$SYSROOT" -target "$TARGET" -arch "$ARCH" \
    -install_name "@rpath/MkxpCore.framework/MkxpCore" \
    -Wl,-exported_symbols_list,"$TREE/gamecore.exports" \
    -L"$ANGLE/lib" \
    -o "$BIN_DIR/MkxpCore" \
    "$BRIDGE" $(cat "$LINK"))

# The engine reads its assets and the Ruby stdlib through its own
# bundle, which dladdr resolves to this framework (filesystemImplIOS.mm).
cp -R "$CORE/assets" "$RES/Assets.bundle"
cp -R "$CORE/$SDK/ruby-stdlib" "$RES/Ruby"

# GameImportValidator reads EmpoCoreRGSSVersionMask at import, before
# any core is open.
finish_framework "$FW" MkxpCore sh.mateo.empo.mkxpcore "$CORE_VERSION" "$CORE/licenses.json" "
	<key>EmpoCoreRGSSVersionMask</key><integer>$RGSS_MASK</integer>"

"$ROOT/cores/mkxp/check-framework.sh" --framework "$FW" --sdk "$SDK"
printf '%s\n' "$WANT_STAMP" >"$STAMP"
echo "[mkxp-framework] Done: $FW"
