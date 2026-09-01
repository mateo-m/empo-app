#!/bin/sh
# Package both iOS native dependency trees into a tarball for empo-deps.
#
# Usage:
#   tools/package-native-deps.sh [release-tag] [--publish]
#
# Requires healthy build-iphoneos-arm64/ and build-iphonesimulator-arm64/
# trees (run scripts/rebuild-all-native-deps.sh first). Writes
# ios/Dependencies/native/.version with the tag and sha256.
#
# With --publish, creates the GitHub Release on empo-deps directly
# (needs a gh auth context with write access). Without it, upload the
# printed tarball manually:
#
#   gh release create <tag> /tmp/native-ios-prebuilt.tar.gz \
#     --repo mateo-m/empo-deps --title "native deps <tag>"

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS_DIR="$REPO_ROOT/ios/Dependencies"
VERSION_FILE="$DEPS_DIR/native/.version"
VERIFY="$REPO_ROOT/scripts/verify-native-deps.sh"
TAG=""
PUBLISH=0

for arg in "$@"; do
    case "$arg" in
        --publish) PUBLISH=1 ;;
        *) TAG="$arg" ;;
    esac
done

if [ -z "$TAG" ]; then
    TAG="native-$(date +%Y-%m-%d)"
fi

echo "==> verifying device tree"
PLATFORM_NAME=iphoneos "$VERIFY"

echo "==> verifying simulator tree"
PLATFORM_NAME=iphonesimulator "$VERIFY"

DEVICE_TREE="$DEPS_DIR/build-iphoneos-arm64"
SIM_TREE="$DEPS_DIR/build-iphonesimulator-arm64"
for tree in "$DEVICE_TREE" "$SIM_TREE"; do
    [ -f "$tree/lib/.deps-fingerprint" ] || {
        echo "error: $tree/lib/.deps-fingerprint missing; rebuild the tree" >&2
        exit 1
    }
    [ -f "$tree/MANIFEST" ] || {
        echo "error: $tree/MANIFEST missing; rebuild the tree" >&2
        exit 1
    }
done
DEPS_FINGERPRINT="$(cat "$DEVICE_TREE/lib/.deps-fingerprint")"
[ "$DEPS_FINGERPRINT" = "$(cat "$SIM_TREE/lib/.deps-fingerprint")" ] || {
    echo "error: the two trees carry different dependency fingerprints; rebuild both from one commit" >&2
    exit 1
}
for field in mode sdk_version; do
    device_value="$(sed -n "s/^$field=//p" "$DEVICE_TREE/MANIFEST")"
    sim_value="$(sed -n "s/^$field=//p" "$SIM_TREE/MANIFEST")"
    [ "$device_value" = "$sim_value" ] || {
        echo "error: $field differs between the trees: iphoneos=$device_value iphonesimulator=$sim_value" >&2
        exit 1
    }
done
SDK_VERSION="$(sed -n 's/^sdk_version=//p' "$DEVICE_TREE/MANIFEST")"

OUT="${TMPDIR:-/tmp}/native-ios-prebuilt.tar.gz"
rm -f "$OUT"

echo "==> packaging into $OUT"
(
    cd "$DEPS_DIR"
    # The tarball excludes engine-core artifacts: they version with
    # the engine submodule (ios/Dependencies/engine/.version, published
    # from the public mkxp-z-apple-mobile repo's CI), not with the
    # deps tree.
    tar -czf "$OUT" \
        --exclude '*/libmkxpz-core.a' \
        --exclude '*/.mkxp-core-fingerprint' \
        --exclude 'build-*/core-obj' \
        build-iphoneos-arm64 \
        build-iphonesimulator-arm64
)

SHA256="$(shasum -a 256 "$OUT" | awk '{print $1}')"

cat >"$VERSION_FILE" <<EOF
# tools/package-native-deps.sh updates this file. Commit it with the release.
NATIVE_DEPS_VERSION=$TAG
NATIVE_DEPS_SHA256=$SHA256
NATIVE_DEPS_FINGERPRINT=$DEPS_FINGERPRINT
NATIVE_DEPS_SDK_VERSION=$SDK_VERSION
EOF

NOTES="${TMPDIR:-/tmp}/native-ios-prebuilt-notes.md"
{
    for tree in "$DEVICE_TREE" "$SIM_TREE"; do
        echo "## $(basename "$tree")"
        echo '```'
        cat "$tree/MANIFEST"
        echo '```'
    done
} >"$NOTES"

echo ""
echo "Packaged: $OUT"
echo "SHA256:   $SHA256"
echo "Updated:  $VERSION_FILE"
echo ""
if [ "$PUBLISH" = "1" ]; then
    # Idempotent: a re-run after a partly failed pipeline must not
    # trip over the already-created release. Same content -> skip.
    # Different content under the same tag -> hard error, because an
    # immutable pin must never move silently.
    if EXISTING_URL="$(gh release view "$TAG" --repo mateo-m/empo-deps \
        --json assets --jq '.assets[] | select(.name == "native-ios-prebuilt.tar.gz") | .url' 2>/dev/null)" &&
        [ -n "$EXISTING_URL" ]; then
        EXISTING_SHA="$(gh release download "$TAG" --repo mateo-m/empo-deps \
            --pattern native-ios-prebuilt.tar.gz --output - | shasum -a 256 | awk '{print $1}')"
        if [ "$EXISTING_SHA" = "$SHA256" ]; then
            echo "==> $TAG already published with identical content, skipping upload"
        else
            echo "error: $TAG already published with DIFFERENT content" >&2
            echo "  published: $EXISTING_SHA" >&2
            echo "  local:     $SHA256" >&2
            exit 1
        fi
    else
        echo "==> publishing to empo-deps as $TAG"
        gh release create "$TAG" "$OUT" \
            --repo mateo-m/empo-deps --title "native deps $TAG" --notes-file "$NOTES"
    fi
else
    echo "Upload:"
    echo "  gh release create $TAG \"$OUT\" --repo mateo-m/empo-deps --title \"native deps $TAG\" --notes-file \"$NOTES\""
fi
