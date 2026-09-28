#!/bin/sh
# Downloads the PSDK core that ios/Dependencies/psdk/.version pins, from
# the releases of mateo-m/psdk-apple-mobile, into
# ios/Dependencies/psdk-core. That repo's CI builds the release from a
# tagged public commit.
#
# The folder holds include/psdk_core.h, <sdk>/libpsdk<NN>.a and
# support/<version>. tools/psdk-core/build-framework-ios.sh links them
# with psdk_app_bridge.cpp.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$REPO_ROOT/ios/Dependencies/psdk/.version"
DEST="$REPO_ROOT/ios/Dependencies/psdk-core"
CORE_REPO=mateo-m/psdk-apple-mobile

# shellcheck disable=SC1090
. "$PIN"
if [ -z "${PSDK_CORE_VERSION:-}" ] || [ -z "${PSDK_CORE_SHA256:-}" ]; then
    echo "error: $PIN must set PSDK_CORE_VERSION and PSDK_CORE_SHA256" >&2
    exit 1
fi

FETCHED="$PSDK_CORE_VERSION $PSDK_CORE_SHA256"
if [ "$(cat "$DEST/.fetched-pin" 2>/dev/null)" = "$FETCHED" ]; then
    exit 0
fi

echo "==> fetching the PSDK core $PSDK_CORE_VERSION from $CORE_REPO"
TAR="${TMPDIR:-/tmp}/psdk-ios.tar.gz"
rm -f "$TAR"
curl -fL --retry 3 -o "$TAR" \
    "https://github.com/$CORE_REPO/releases/download/$PSDK_CORE_VERSION/psdk-ios.tar.gz"
echo "$PSDK_CORE_SHA256  $TAR" | shasum -a 256 -c >/dev/null || {
    echo "error: psdk-ios.tar.gz does not match PSDK_CORE_SHA256 in $PIN" >&2
    exit 1
}

rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf "$TAR" -C "$DEST"
rm -f "$TAR"
printf '%s\n' "$FETCHED" >"$DEST/.fetched-pin"
