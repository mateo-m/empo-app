#!/bin/sh
# Hydrate ios/Dependencies/ANGLE/ with the prebuilt static libs +
# headers from the empo-deps repo.
#
# - Reads version + expected sha256 from ios/Dependencies/ANGLE/.version
# - Skips work when a stamp file matches the requested version and the
#   binaries are already on disk
# - Uses `gh release download` so auth piggybacks on the contributor's
#   GitHub login (no PATs to manage). When empo-deps goes public, swap
#   to plain curl (no auth needed for public release assets).
# - Verifies the downloaded tarball's sha256 before extracting

set -e

# Anchor paths off PROJECT_DIR when running as an Xcode build phase,
# fall back to the script's own location for manual invocation.
if [ -n "$PROJECT_DIR" ]; then
    REPO_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"
else
    REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

ANGLE_DIR="$REPO_ROOT/ios/Dependencies/ANGLE"
VERSION_FILE="$ANGLE_DIR/.version"
STAMP="$ANGLE_DIR/.fetched-version"
DEPS_REPO="${EMPO_DEPS_REPO:-mateo-m/empo-deps}"
ASSET_NAME="angle-ios-prebuilt.tar.gz"

if [ ! -f "$VERSION_FILE" ]; then
    echo "fetch-angle: $VERSION_FILE missing; cannot resolve ANGLE version" >&2
    exit 1
fi

# shellcheck disable=SC1090
. "$VERSION_FILE" # sets ANGLE_VERSION + ANGLE_SHA256

if [ -z "$ANGLE_VERSION" ] || [ -z "$ANGLE_SHA256" ]; then
    echo "fetch-angle: $VERSION_FILE must define ANGLE_VERSION and ANGLE_SHA256" >&2
    exit 1
fi

# Already hydrated and stamp matches the pinned version? nothing to do.
if [ -f "$STAMP" ] &&
    [ "$(cat "$STAMP" 2>/dev/null)" = "$ANGLE_VERSION" ] &&
    [ -f "$ANGLE_DIR/iphoneos/lib/libANGLE_static.a" ] &&
    [ -f "$ANGLE_DIR/iphonesimulator/lib/libANGLE_static.a" ]; then
    exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
    cat >&2 <<MSG
fetch-angle: \`gh\` CLI not found.

Install with: brew install gh && gh auth login

empo-deps is a private repo for now; the build needs gh to download
its release assets. When empo-deps goes public this script will
fall back to plain curl.
MSG
    exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "fetch-angle: hydrating $ANGLE_VERSION from $DEPS_REPO"

if ! gh release download "$ANGLE_VERSION" \
    --repo "$DEPS_REPO" \
    --pattern "$ASSET_NAME" \
    --dir "$TMPDIR" \
    --skip-existing 2>&1; then
    echo "fetch-angle: gh release download failed for $DEPS_REPO@$ANGLE_VERSION" >&2
    exit 1
fi

ACTUAL_SHA="$(shasum -a 256 "$TMPDIR/$ASSET_NAME" | awk '{print $1}')"
if [ "$ACTUAL_SHA" != "$ANGLE_SHA256" ]; then
    echo "fetch-angle: sha256 mismatch" >&2
    echo "  expected: $ANGLE_SHA256" >&2
    echo "  actual:   $ACTUAL_SHA" >&2
    exit 1
fi

# Extract into the ANGLE dir. The tarball ships paths relative to
# ANGLE_DIR (iphoneos/include, iphoneos/lib, iphonesimulator/include,
# iphonesimulator/lib).
mkdir -p "$ANGLE_DIR"
tar -xzf "$TMPDIR/$ASSET_NAME" -C "$ANGLE_DIR"

echo "$ANGLE_VERSION" >"$STAMP"
echo "fetch-angle: hydrated $ANGLE_VERSION ($ANGLE_SHA256)"
