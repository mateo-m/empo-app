#!/bin/sh
# Downloads the MV/MZ core that ios/Dependencies/mvmz/.version pins, from
# the releases of mateo-m/mvmz-apple-mobile, into
# ios/Dependencies/mvmz-core. That repo's CI builds the release from a
# tagged public commit.
#
# The folder holds include/mvmz_core.h and <sdk>/libmvmz.a. The MvmzCore
# target links them with mvmz_app_bridge.m.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$REPO_ROOT/ios/Dependencies/mvmz/.version"
DEST="$REPO_ROOT/ios/Dependencies/mvmz-core"
CORE_REPO=mateo-m/mvmz-apple-mobile

# Xcode and a script can run this at the same time. lockf runs one at a
# time, and the second then finds the core in place.
if [ -z "${MVMZ_CORE_LOCKED:-}" ]; then
    MVMZ_CORE_LOCKED=1 exec lockf -k "$DEST.lock" "$0" "$@"
fi

# shellcheck disable=SC1090
. "$PIN"
if [ -z "${MVMZ_CORE_VERSION:-}" ] || [ -z "${MVMZ_CORE_SHA256:-}" ]; then
    echo "error: $PIN must set MVMZ_CORE_VERSION and MVMZ_CORE_SHA256" >&2
    exit 1
fi

FETCHED="$MVMZ_CORE_VERSION $MVMZ_CORE_SHA256"
if [ "$(cat "$DEST/.fetched-pin" 2>/dev/null)" = "$FETCHED" ]; then
    exit 0
fi

echo "==> fetching the MV/MZ core $MVMZ_CORE_VERSION from $CORE_REPO"
WORK="$(mktemp -d "$DEST.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
TAR="$WORK/mvmz-ios.tar.gz"
curl -fL --retry 3 -o "$TAR" \
    "https://github.com/$CORE_REPO/releases/download/$MVMZ_CORE_VERSION/mvmz-ios.tar.gz"
echo "$MVMZ_CORE_SHA256  $TAR" | shasum -a 256 -c >/dev/null || {
    echo "error: mvmz-ios.tar.gz does not match MVMZ_CORE_SHA256 in $PIN" >&2
    exit 1
}

mkdir "$WORK/core"
tar -xzf "$TAR" -C "$WORK/core"
printf '%s\n' "$FETCHED" >"$WORK/core/.fetched-pin"
rm -rf "$DEST"
mv "$WORK/core" "$DEST"
