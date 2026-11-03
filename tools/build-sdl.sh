#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Builds the SDL release that ios/Dependencies/SDL/.version pins into
# ios/Dependencies/SDL/macosx: a static libSDL3.a with only the
# controller parts, its headers, and gamecontrollerdb.txt. The Mac app
# and Empo Player read every controller through it.
set -euo pipefail

if [ -n "${PROJECT_DIR:-}" ]; then
    REPO_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"
else
    REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
SDL_DIR="$REPO_ROOT/ios/Dependencies/SDL"
PIN="$SDL_DIR/.version"
DEST="$SDL_DIR/macosx"

# Xcode builds EmpoMac and Empo Player at the same time. lockf runs one
# build, and the second then finds the library in place.
if [ -z "${SDL_BUILD_LOCKED:-}" ]; then
    mkdir -p "$SDL_DIR"
    SDL_BUILD_LOCKED=1 exec lockf -k "$SDL_DIR/.lock" "$0" "$@"
fi

# shellcheck disable=SC1090
. "$PIN"
BUILT="$SDL_VERSION $SDL_SHA256 $GAMECONTROLLERDB_COMMIT $GAMECONTROLLERDB_SHA256"
if [ "$(cat "$DEST/.built-pin" 2>/dev/null)" = "$BUILT" ]; then
    exit 0
fi

# An Xcode build phase does not get the PATH of a login shell.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
command -v cmake >/dev/null || {
    echo "error: building SDL needs cmake. Install it with: brew install cmake" >&2
    exit 1
}

WORK="$(mktemp -d "$SDL_DIR/work.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "==> fetching SDL $SDL_VERSION"
curl -fL --retry 3 -o "$WORK/sdl.tar.gz" \
    "https://github.com/libsdl-org/SDL/releases/download/release-$SDL_VERSION/SDL3-$SDL_VERSION.tar.gz"
echo "$SDL_SHA256  $WORK/sdl.tar.gz" | shasum -a 256 -c >/dev/null || {
    echo "error: the SDL download does not match SDL_SHA256 in $PIN" >&2
    exit 1
}
curl -fL --retry 3 -o "$WORK/gamecontrollerdb.txt" \
    "https://raw.githubusercontent.com/mdqinc/SDL_GameControllerDB/$GAMECONTROLLERDB_COMMIT/gamecontrollerdb.txt"
echo "$GAMECONTROLLERDB_SHA256  $WORK/gamecontrollerdb.txt" | shasum -a 256 -c >/dev/null || {
    echo "error: gamecontrollerdb.txt does not match GAMECONTROLLERDB_SHA256 in $PIN" >&2
    exit 1
}
tar -xzf "$WORK/sdl.tar.gz" -C "$WORK"

# Xcode exports SDKROOT, ARCHS and other settings for iOS or macOS to
# its build phases. They must not reach this macOS build. DEVELOPER_DIR
# picks the Xcode, and the app builds with that Xcode too.
CLEAN_ENV=(env -i HOME="$HOME" PATH="$PATH" ${DEVELOPER_DIR:+DEVELOPER_DIR="$DEVELOPER_DIR"})
"${CLEAN_ENV[@]}" cmake -S "$WORK/SDL3-$SDL_VERSION" -B "$WORK/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DCMAKE_INSTALL_PREFIX="$WORK/out" \
    -DSDL_SHARED=OFF -DSDL_STATIC=ON \
    -DSDL_TEST_LIBRARY=OFF -DSDL_EXAMPLES=OFF \
    -DSDL_AUDIO=OFF -DSDL_VIDEO=OFF -DSDL_HAPTIC=OFF -DSDL_POWER=OFF \
    -DSDL_DIALOG=OFF -DSDL_TRAY=OFF -DSDL_HIDAPI_LIBUSB=OFF \
    >"$WORK/configure.log" || {
    cat "$WORK/configure.log" >&2
    exit 1
}
"${CLEAN_ENV[@]}" cmake --build "$WORK/build" --parallel >"$WORK/build.log" || {
    tail -n 40 "$WORK/build.log" >&2
    exit 1
}
"${CLEAN_ENV[@]}" cmake --install "$WORK/build" >/dev/null

mkdir "$WORK/macosx" "$WORK/macosx/lib"
cp "$WORK/out/lib/libSDL3.a" "$WORK/macosx/lib/"
cp -R "$WORK/out/include" "$WORK/macosx/include"
cp "$WORK/gamecontrollerdb.txt" "$WORK/macosx/"
printf '%s\n' "$BUILT" >"$WORK/macosx/.built-pin"
rm -rf "$DEST"
mv "$WORK/macosx" "$DEST"
