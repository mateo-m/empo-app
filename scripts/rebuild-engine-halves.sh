#!/usr/bin/env bash
# Rebuild mkxp{18,19,31}-merged.o and libmkxpz-core.a on top of a
# dependency half that an earlier full rebuild produced. The tree must
# carry a .deps-fingerprint stamp equal to the value for this checkout.
# When it does not, run scripts/rebuild-<device|simulator>-deps.sh.
#
# Usage:
#   scripts/rebuild-engine-halves.sh <iphoneos|iphonesimulator> [--hydrate]
#
# --hydrate downloads the release pinned in ios/Dependencies/native/.version
# and replaces the tree with it first. Without it the tree on disk is
# the base, which is what an Xcode build left there.
set -euo pipefail

SDK="${1:?usage: $0 <iphoneos|iphonesimulator> [--hydrate]}"
HYDRATE=0
case "$SDK" in
    iphoneos | iphonesimulator) ;;
    *)
        echo "usage: $0 <iphoneos|iphonesimulator> [--hydrate]" >&2
        exit 2
        ;;
esac
[[ "${2:-}" == "" || "${2:-}" == "--hydrate" ]] || {
    echo "usage: $0 <iphoneos|iphonesimulator> [--hydrate]" >&2
    exit 2
}
[[ "${2:-}" == "--hydrate" ]] && HYDRATE=1

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$REPO_ROOT/ios/Dependencies"
TREE="$DEPS/build-$SDK-arm64"
LIB="$TREE/lib"
VERSION_FILE="$DEPS/native/.version"
DEPS_REPO="${EMPO_DEPS_REPO:-mateo-m/empo-deps}"
ASSET_NAME="native-ios-prebuilt.tar.gz"

fail() {
    echo "error: $*" >&2
    exit 1
}

# Every file the engine build writes into the tree. Everything else is
# the dependency half and must not change. A new engine output shows
# up as a changed file and fails the run. Add it here on purpose.
is_engine_output() {
    case "$1" in
        ./binding18/* | ./binding19/* | ./binding31/* | ./core-obj/*) return 0 ;;
        ./lib/mkxp18-merged.o | ./lib/mkxp19-merged.o | ./lib/mkxp31-merged.o) return 0 ;;
        ./lib/.mkxp-binding-fingerprint | ./lib/.mkxp-core-fingerprint | ./lib/libmkxpz-core.a) return 0 ;;
        ./ruby18-unexports.txt | ./ruby19-unexports.txt | ./ruby31-unexports.txt) return 0 ;;
        ./MANIFEST) return 0 ;;
    esac
    return 1
}

snapshot_dependency_half() {
    (
        cd "$TREE"
        find . -type f | LC_ALL=C sort | while IFS= read -r f; do
            is_engine_output "$f" || printf '%s\n' "$f"
        done | xargs shasum -a 256
    )
}

CURRENT="$("$REPO_ROOT/tools/deps-fingerprint.sh" --require-clean)"
# shellcheck disable=SC1090
. "$VERSION_FILE"

if [[ "$HYDRATE" == 1 ]]; then
    [[ "$NATIVE_DEPS_VERSION" != "unpublished" ]] || fail "no published base to hydrate (NATIVE_DEPS_VERSION=unpublished)"
    [[ -n "${NATIVE_DEPS_SHA256:-}" ]] || fail "NATIVE_DEPS_SHA256 is empty in $VERSION_FILE"
    DL="$(mktemp -d "${TMPDIR:-/tmp}/empo-engine-halves.XXXXXX")"
    trap 'rm -rf "$DL"' EXIT INT TERM
    echo "==> downloading $NATIVE_DEPS_VERSION from $DEPS_REPO"
    gh release download "$NATIVE_DEPS_VERSION" --repo "$DEPS_REPO" --pattern "$ASSET_NAME" --dir "$DL"
    ACTUAL="$(shasum -a 256 "$DL/$ASSET_NAME" | awk '{print $1}')"
    [[ "$ACTUAL" == "$NATIVE_DEPS_SHA256" ]] || fail "sha256 mismatch for $NATIVE_DEPS_VERSION: expected $NATIVE_DEPS_SHA256, got $ACTUAL"
    rm -rf "$TREE"
    tar -xzf "$DL/$ASSET_NAME" -C "$DEPS" "build-$SDK-arm64"
fi

[[ -d "$TREE" ]] || fail "$TREE does not exist; pass --hydrate or run the full rebuild"
[[ -f "$LIB/.deps-fingerprint" ]] || fail "$LIB/.deps-fingerprint missing: this tree predates the stamp; run the full rebuild"
[[ -f "$TREE/MANIFEST" ]] || fail "$TREE/MANIFEST missing: this tree predates the manifest; run the full rebuild"

RECORDED="$(cat "$LIB/.deps-fingerprint")"
if [[ "$RECORDED" != "$CURRENT" ]]; then
    fail "dependency inputs changed since this tree was built; run the full rebuild
  tree:     $RECORDED
  checkout: $CURRENT"
fi

TREE_SDK_VERSION="$(sed -n 's/^sdk_version=//p' "$TREE/MANIFEST")"
SDK_VERSION="$(xcrun --sdk "$SDK" --show-sdk-version)"
[[ "$TREE_SDK_VERSION" == "$SDK_VERSION" ]] ||
    fail "the tree was built with SDK $TREE_SDK_VERSION and this Mac has $SDK_VERSION; run the full rebuild"

DEPS_BUILT_AT="$(sed -n 's/^deps_built_at=//p' "$TREE/MANIFEST")"
BASE_TAG="$(sed -n 's/^base_tag=//p' "$TREE/MANIFEST")"
[[ "$HYDRATE" == 0 ]] || BASE_TAG="$NATIVE_DEPS_VERSION"

echo "==> recording the dependency half"
BEFORE="$(snapshot_dependency_half)"

echo "==> removing engine outputs"
(
    cd "$TREE"
    rm -rf binding18 binding19 binding31 core-obj
    rm -f lib/mkxp18-merged.o lib/mkxp19-merged.o lib/mkxp31-merged.o
    rm -f lib/.mkxp-binding-fingerprint lib/.mkxp-core-fingerprint lib/libmkxpz-core.a
    rm -f ruby18-unexports.txt ruby19-unexports.txt ruby31-unexports.txt
)

echo "==> building mkxp{18,19,31}-merged.o and libmkxpz-core.a"
(
    cd "$DEPS"
    # -o: the archive is final. make must not look at its rule, which
    # reaches into the source tree for a .configured-* stamp that a
    # fresh checkout does not have.
    make -f "$SDK.make" \
        -o "$LIB/libruby.3.1-static.a" -o "$LIB/libruby.3.1-ext.a" \
        -o "$LIB/libruby18-static.a" -o "$LIB/libruby18-ext.a" \
        -o "$LIB/libruby19-static.a" -o "$LIB/libruby19-ext.a" \
        engine-halves
)

echo "==> checking the dependency half did not change"
AFTER="$(snapshot_dependency_half)"
if [[ "$BEFORE" != "$AFTER" ]]; then
    diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") >&2 || true
    fail "the engine build changed files in the dependency half of $TREE"
fi

PLATFORM_NAME="$SDK" "$REPO_ROOT/scripts/verify-native-deps.sh"
"$REPO_ROOT/scripts/write-deps-manifest.sh" "$SDK" engine "$DEPS_BUILT_AT" "$BASE_TAG"
echo "==> $SDK engine halves rebuilt on $BASE_TAG"
