#!/bin/sh
# Hydrate the prebuilt engine-core libraries (libmkxpz-core.a per SDK)
# from a published artifact on the PUBLIC mkxp-z-apple-mobile repo.
#
# That repo's CI (.github/workflows/artifacts.yml) builds the
# artifact from a tagged public commit, so the shipped binary provably
# corresponds to public GPL source. ios/Dependencies/engine/.version
# pins it by version+sha256.
#
# Local-source dev path (publishing never blocks it):
#   - ENGINE_VERSION=unpublished in the pin file, or
#   - EMPO_ENGINE_FROM_SOURCE=1 in the environment
# both skip the fetch entirely. Build with:
#   cd ios/Dependencies && make -f <platform>.make mkxp-core
# scripts/verify-native-deps.sh enforces freshness either way via the
# .mkxp-core-fingerprint stamp, so a fetched artifact that does not
# match the checked-out submodule fails the build instead of shipping.
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS_DIR="$REPO_ROOT/ios/Dependencies"
VERSION_FILE="$DEPS_DIR/engine/.version"
STAMP_FILE="$DEPS_DIR/engine/.fetched-version"
ENGINE_REPO="mateo-m/mkxp-z-apple-mobile"

if [ "${EMPO_ENGINE_FROM_SOURCE:-0}" = "1" ]; then
    echo "engine prebuilt: EMPO_ENGINE_FROM_SOURCE=1, using locally built core"
    exit 0
fi

if [ ! -f "$VERSION_FILE" ]; then
    echo "error: $VERSION_FILE missing" >&2
    exit 1
fi

# shellcheck disable=SC1090
. "$VERSION_FILE"

if [ -z "${ENGINE_VERSION:-}" ]; then
    echo "error: ENGINE_VERSION not set in $VERSION_FILE" >&2
    exit 1
fi

if [ "$ENGINE_VERSION" = "unpublished" ]; then
    echo "engine prebuilt: pin is 'unpublished', using locally built core"
    exit 0
fi

have_libs() {
    [ -f "$DEPS_DIR/build-iphoneos-arm64/lib/libmkxpz-core.a" ] &&
        [ -f "$DEPS_DIR/build-iphonesimulator-arm64/lib/libmkxpz-core.a" ]
}

if [ -f "$STAMP_FILE" ] && [ "$(cat "$STAMP_FILE")" = "$ENGINE_VERSION" ] && have_libs; then
    exit 0
fi

echo "==> fetching engine prebuilt $ENGINE_VERSION from $ENGINE_REPO"
TMP_TAR="${TMPDIR:-/tmp}/engine-ios-prebuilt.tar.gz"
rm -f "$TMP_TAR"
curl -fL --retry 3 -o "$TMP_TAR" \
    "https://github.com/$ENGINE_REPO/releases/download/$ENGINE_VERSION/engine-ios-prebuilt.tar.gz"

ACTUAL_SHA="$(shasum -a 256 "$TMP_TAR" | awk '{print $1}')"
if [ "$ACTUAL_SHA" != "${ENGINE_SHA256:-}" ]; then
    echo "error: engine prebuilt sha256 mismatch" >&2
    echo "  pinned: ${ENGINE_SHA256:-<empty>}" >&2
    echo "  actual: $ACTUAL_SHA" >&2
    exit 1
fi

# Tarball layout: <sdk>/lib/{libmkxpz-core.a,.mkxp-core-fingerprint}
EXTRACT_DIR="${TMPDIR:-/tmp}/engine-ios-prebuilt.extract"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$TMP_TAR" -C "$EXTRACT_DIR"

for sdk in iphoneos iphonesimulator; do
    src="$EXTRACT_DIR/$sdk/lib"
    dst="$DEPS_DIR/build-$sdk-arm64/lib"
    [ -f "$src/libmkxpz-core.a" ] || {
        echo "error: tarball missing $sdk/lib/libmkxpz-core.a" >&2
        exit 1
    }
    mkdir -p "$dst"
    cp "$src/libmkxpz-core.a" "$dst/libmkxpz-core.a"
    cp "$src/.mkxp-core-fingerprint" "$dst/.mkxp-core-fingerprint"
done

rm -rf "$EXTRACT_DIR" "$TMP_TAR"
printf '%s\n' "$ENGINE_VERSION" >"$STAMP_FILE"
echo "==> engine prebuilt $ENGINE_VERSION hydrated"
