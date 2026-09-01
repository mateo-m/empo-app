#!/usr/bin/env bash
# Write build-<sdk>-arm64/MANIFEST. The rebuild scripts call it once
# the tree verifies. tools/package-native-deps.sh copies it into the
# release notes.
#
# Usage: scripts/write-deps-manifest.sh <iphoneos|iphonesimulator> <full|engine> <deps-built-at> <base-tag>
set -euo pipefail

SDK="${1:?usage: $0 <iphoneos|iphonesimulator> <full|engine> <deps-built-at> <base-tag>}"
MODE="${2:?missing mode}"
DEPS_BUILT_AT="${3:?missing deps-built-at}"
BASE_TAG="${4:?missing base-tag}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TREE="$REPO_ROOT/ios/Dependencies/build-$SDK-arm64"
ENGINE="$REPO_ROOT/mkxp-z-apple-mobile"

# A copy of the engine without .git makes git walk up to the top repo
# and answer with the wrong HEAD, so ask for the gitlink in that case.
if [[ -e "$ENGINE/.git" ]]; then
    ENGINE_COMMIT="$(git -C "$ENGINE" rev-parse HEAD)"
else
    ENGINE_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD:mkxp-z-apple-mobile)"
fi

cat >"$TREE/MANIFEST" <<MANIFEST
mode=$MODE
sdk=$SDK
sdk_version=$(xcrun --sdk "$SDK" --show-sdk-version)
xcode_build=$(xcodebuild -version | sed -n 's/^Build version //p')
deps_fingerprint=$(cat "$TREE/lib/.deps-fingerprint")
deps_built_at=$DEPS_BUILT_AT
base_tag=$BASE_TAG
empo_commit=$(git -C "$REPO_ROOT" rev-parse HEAD)
engine_commit=$ENGINE_COMMIT
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST
echo "==> wrote $TREE/MANIFEST"
