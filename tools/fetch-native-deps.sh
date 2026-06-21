#!/bin/sh
# Hydrate ios/Dependencies/build-{iphoneos,iphonesimulator}-arm64/ from
# prebuilt tarballs on the empo-deps repo (ANGLE-style fetch-on-build).
#
# Daily workflow: Xcode builds fetch (or no-op when stamp + trees match).
# Dep bumps: CI publishes a new release asset; bump native/.version here.
#
# Escape hatch for maintainers building locally:
#   IOS_DEPS_SKIP_FETCH=1  — never download; require local trees.
#   NATIVE_DEPS_VERSION=unpublished — no remote asset; use local trees only.

set -e

if [ -n "$PROJECT_DIR" ]; then
    REPO_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"
else
    REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

DEPS_DIR="$REPO_ROOT/ios/Dependencies"
VERSION_FILE="$DEPS_DIR/native/.version"
STAMP="$DEPS_DIR/native/.fetched-version"
DEPS_REPO="${EMPO_DEPS_REPO:-mateo-m/empo-deps}"
ASSET_NAME="native-ios-prebuilt.tar.gz"
VERIFY="$REPO_ROOT/scripts/verify-native-deps.sh"

if [ ! -f "$VERSION_FILE" ]; then
    echo "fetch-native-deps: $VERSION_FILE missing" >&2
    exit 1
fi

# shellcheck disable=SC1090
. "$VERSION_FILE"

if [ -z "$NATIVE_DEPS_VERSION" ]; then
    echo "fetch-native-deps: NATIVE_DEPS_VERSION must be set in $VERSION_FILE" >&2
    exit 1
fi

verify_both_trees() {
    PLATFORM_NAME=iphoneos "$VERIFY" && PLATFORM_NAME=iphonesimulator "$VERIFY"
}

both_build_trees_exist() {
    [ -d "$DEPS_DIR/build-iphoneos-arm64" ] &&
        [ -d "$DEPS_DIR/build-iphonesimulator-arm64" ]
}

# Stamp matches and both SDK trees are present — nothing to do.
# Full verification runs after download and in the dedicated Xcode phase.
if [ -f "$STAMP" ] &&
    [ "$(cat "$STAMP" 2>/dev/null)" = "$NATIVE_DEPS_VERSION" ] &&
    both_build_trees_exist; then
    exit 0
fi

if [ "$IOS_DEPS_SKIP_FETCH" = "1" ]; then
    if verify_both_trees; then
        echo "$NATIVE_DEPS_VERSION" >"$STAMP"
        exit 0
    fi
    echo "fetch-native-deps: IOS_DEPS_SKIP_FETCH=1 but local trees failed verification" >&2
    echo "hint: scripts/rebuild-all-native-deps.sh" >&2
    exit 1
fi

# Unpublished pin: local trees only (no empo-deps download yet).
if [ "$NATIVE_DEPS_VERSION" = "unpublished" ]; then
    if verify_both_trees; then
        echo "$NATIVE_DEPS_VERSION" >"$STAMP"
        exit 0
    fi
    cat >&2 <<MSG
fetch-native-deps: native deps are not published yet (NATIVE_DEPS_VERSION=unpublished).

Build both SDK trees once, then switch Xcode destinations freely:

  scripts/rebuild-all-native-deps.sh

To publish prebuilts for the team, run tools/package-native-deps.sh and
upload the tarball to empo-deps, then bump ios/Dependencies/native/.version.
MSG
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    cat >&2 <<MSG
fetch-native-deps: \`gh\` CLI not found (needed to download $NATIVE_DEPS_VERSION).

Install: brew install gh && gh auth login

Or build locally: scripts/rebuild-all-native-deps.sh
MSG
    exit 1
fi

TMPDIR_DL=$(mktemp -d "${TMPDIR:-/tmp}/empo-native-deps.XXXXXX")
trap 'rm -rf "$TMPDIR_DL"' EXIT INT TERM

echo "fetch-native-deps: downloading $NATIVE_DEPS_VERSION from $DEPS_REPO"

if ! gh release download "$NATIVE_DEPS_VERSION" \
    --repo "$DEPS_REPO" \
    --pattern "$ASSET_NAME" \
    --dir "$TMPDIR_DL" \
    --skip-existing 2>&1; then
    echo "fetch-native-deps: gh release download failed for $DEPS_REPO@$NATIVE_DEPS_VERSION" >&2
    exit 1
fi

if [ -n "$NATIVE_DEPS_SHA256" ]; then
    ACTUAL_SHA="$(shasum -a 256 "$TMPDIR_DL/$ASSET_NAME" | awk '{print $1}')"
    if [ "$ACTUAL_SHA" != "$NATIVE_DEPS_SHA256" ]; then
        echo "fetch-native-deps: sha256 mismatch" >&2
        echo "  expected: $NATIVE_DEPS_SHA256" >&2
        echo "  actual:   $ACTUAL_SHA" >&2
        exit 1
    fi
else
    echo "fetch-native-deps: warning: NATIVE_DEPS_SHA256 empty, skipping checksum verify" >&2
fi

# Tarball paths are relative to ios/Dependencies/ (build-iphoneos-arm64/, …).
for dir in build-iphoneos-arm64 build-iphonesimulator-arm64; do
    rm -rf "${DEPS_DIR:?}/$dir"
done
tar -xzf "$TMPDIR_DL/$ASSET_NAME" -C "$DEPS_DIR"

if ! verify_both_trees; then
    echo "fetch-native-deps: extracted tarball failed verification" >&2
    exit 1
fi

echo "$NATIVE_DEPS_VERSION" >"$STAMP"
echo "fetch-native-deps: hydrated $NATIVE_DEPS_VERSION"
