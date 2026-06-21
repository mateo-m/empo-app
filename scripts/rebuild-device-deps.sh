#!/usr/bin/env bash
# Clean-rebuild all iphoneos native deps Empo links against.
#
# Encodes the known-good sequence from BUILD_PIPELINE_ISSUES.md: nuke
# stale autotools/cmake/ruby artifacts, rebuild deps sequentially (no
# parallel races), force Ruby 3.1 extensions before mkxp-merged.
#
# Usage: scripts/rebuild-device-deps.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$REPO_ROOT/ios/Dependencies"
LIB="$DEPS/build-iphoneos-arm64/lib"

echo "==> cleaning ruby/SDL/freetype source artifacts"
for d in sources/ruby sources/ruby19 sources/ruby18 sources/sdl2_ttf sources/freetype; do
    (cd "$DEPS/$d" && git checkout -- . 2>/dev/null && git clean -fdx >/dev/null 2>&1)
done

echo "==> removing device build output and per-SDK configure stamps"
OPENSSL_DIR="$DEPS/downloads/aarch64-apple-darwin/openssl-1.1.1w"
if [[ -f "$OPENSSL_DIR/Makefile" ]]; then
    make -C "$OPENSSL_DIR" distclean >/dev/null 2>&1 || true
fi
find "$DEPS" -name '.configured-*' -delete 2>/dev/null || true
rm -f "$OPENSSL_DIR"/.configured-*
rm -rf "$DEPS/build-iphoneos-arm64"
find "$DEPS/sources" "$DEPS/downloads" -maxdepth 3 -type d -name 'cmakebuild-*' -prune -exec rm -rf {} + 2>/dev/null || true

cd "$DEPS"

echo "==> building core deps (sequential)"
make -f iphoneos.make libogg libvorbis
make -f iphoneos.make freetype
make -f iphoneos.make deps-core

echo "==> building Ruby 1.8 / 1.9"
make -f iphoneos.make ruby19 ruby18

echo "==> building Ruby 3.1 static lib"
make -f iphoneos.make "$LIB/libruby.3.1-static.a"

echo "==> building Ruby 3.1 extensions + mkxp merged (via common.make)"
rm -f "$LIB/libruby.3.1-ext.a"
make -f iphoneos.make "$LIB/libruby.3.1-ext.a"

echo "==> building mkxp{18,19,31}-merged.o"
make -f iphoneos.make mkxp-merged

echo "==> device deps rebuild complete"
PLATFORM_NAME=iphoneos "$REPO_ROOT/scripts/verify-native-deps.sh"
