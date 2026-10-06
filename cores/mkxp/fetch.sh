#!/bin/sh
# Downloads the engine that cores/mkxp/.version pins, from
# the releases of mateo-m/mkxp-z-apple-mobile, into
# ios/Dependencies/mkxp-core. That repo's CI builds the release from a
# tagged public commit.
#
# The folder holds include/app_bridge.h, the engine assets, and the
# libraries of each SDK with a LINK file that lists them.
# cores/mkxp/build-framework-ios.sh links them into
# MkxpCore.framework.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="$REPO_ROOT/cores/mkxp/.version"
DEST="$REPO_ROOT/ios/Dependencies/mkxp-core"
CORE_REPO=mateo-m/mkxp-z-apple-mobile

# Xcode and a script can run this at the same time. lockf runs one at a
# time, and the second then finds the core in place.
if [ -z "${MKXP_CORE_LOCKED:-}" ]; then
    MKXP_CORE_LOCKED=1 exec lockf -k "$DEST.lock" "$0" "$@"
fi

# shellcheck disable=SC1090
. "$PIN"
if [ -z "${MKXP_CORE_VERSION:-}" ] || [ -z "${MKXP_CORE_SHA256:-}" ]; then
    echo "error: $PIN must set MKXP_CORE_VERSION and MKXP_CORE_SHA256" >&2
    exit 1
fi

FETCHED="$MKXP_CORE_VERSION $MKXP_CORE_SHA256"
if [ "$(cat "$DEST/.fetched-pin" 2>/dev/null)" = "$FETCHED" ]; then
    exit 0
fi

WORK="$(mktemp -d "$DEST.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
TAR="$WORK/mkxp-z-ios.tar.gz"
# A local build of the engine, to test it before its release. The pin
# must give its sha256.
if [ -f "$DEST.tar.gz" ]; then
    echo "==> using the local engine $DEST.tar.gz"
    cp "$DEST.tar.gz" "$TAR"
else
    echo "==> fetching the engine $MKXP_CORE_VERSION from $CORE_REPO"
    curl -fL --retry 3 -o "$TAR" \
        "https://github.com/$CORE_REPO/releases/download/$MKXP_CORE_VERSION/mkxp-z-ios.tar.gz"
fi
echo "$MKXP_CORE_SHA256  $TAR" | shasum -a 256 -c >/dev/null || {
    echo "error: mkxp-z-ios.tar.gz does not match MKXP_CORE_SHA256 in $PIN" >&2
    exit 1
}

mkdir "$WORK/core"
tar -xzf "$TAR" -C "$WORK/core"
printf '%s\n' "$FETCHED" >"$WORK/core/.fetched-pin"
rm -rf "$DEST"
mv "$WORK/core" "$DEST"
