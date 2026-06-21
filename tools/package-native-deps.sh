#!/bin/sh
# Package both iOS native dependency trees into a tarball for empo-deps.
#
# Usage:
#   tools/package-native-deps.sh [release-tag]
#
# Requires healthy build-iphoneos-arm64/ and build-iphonesimulator-arm64/
# trees (run scripts/rebuild-all-native-deps.sh first). Writes
# ios/Dependencies/native/.version with the tag and sha256. Upload the
# printed tarball to a GitHub Release on empo-deps:
#
#   gh release create <tag> /tmp/native-ios-prebuilt.tar.gz \
#     --repo mateo-m/empo-deps --title "native deps <tag>"

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS_DIR="$REPO_ROOT/ios/Dependencies"
VERSION_FILE="$DEPS_DIR/native/.version"
VERIFY="$REPO_ROOT/scripts/verify-native-deps.sh"
TAG="${1:-}"

if [ -z "$TAG" ]; then
    TAG="native-$(date +%Y-%m-%d)"
fi

echo "==> verifying device tree"
PLATFORM_NAME=iphoneos "$VERIFY"

echo "==> verifying simulator tree"
PLATFORM_NAME=iphonesimulator "$VERIFY"

OUT="${TMPDIR:-/tmp}/native-ios-prebuilt.tar.gz"
rm -f "$OUT"

echo "==> packaging into $OUT"
(
    cd "$DEPS_DIR"
    tar -czf "$OUT" \
        build-iphoneos-arm64 \
        build-iphonesimulator-arm64
)

SHA256="$(shasum -a 256 "$OUT" | awk '{print $1}')"

cat >"$VERSION_FILE" <<EOF
# Auto-updated by tools/package-native-deps.sh — commit with the release.
NATIVE_DEPS_VERSION=$TAG
NATIVE_DEPS_SHA256=$SHA256
EOF

echo ""
echo "Packaged: $OUT"
echo "SHA256:   $SHA256"
echo "Updated:  $VERSION_FILE"
echo ""
echo "Upload:"
echo "  gh release create $TAG \"$OUT\" --repo mateo-m/empo-deps --title \"native deps $TAG\""
