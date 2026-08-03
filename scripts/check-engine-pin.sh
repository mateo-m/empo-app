#!/usr/bin/env bash
# Preflight for the engine-core prebuilt pin.
#
# The tag in ENGINE_VERSION must carry the same engine core sources
# (src/**/*.{c,cpp,mm,h}) as the committed submodule gitlink. When
# they differ, the fetched libmkxpz-core.a fails the fingerprint
# check in scripts/verify-native-deps.sh, but only late in the Xcode
# build. This check finds the same mismatch in seconds.
#
# Callers:
#   scripts/hooks/pre-push.sh   local hook; uses the submodule checkout
#   .github/workflows/ci.yml    submodule-guard job; sets ENGINE_REPO_DIR
#                               and GITLINK_SHA for its temporary clone
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_REPO_DIR="${ENGINE_REPO_DIR:-$REPO_ROOT/mkxp-z-apple-mobile}"
PIN_FILE="$REPO_ROOT/ios/Dependencies/engine/.version"

fail() {
    echo "error: $*" >&2
    exit 1
}

# Read the pin and the gitlink from HEAD. A push publishes HEAD, so
# an uncommitted pin edit in the worktree must not satisfy the check.
ENGINE_VERSION="$(git -C "$REPO_ROOT" show HEAD:ios/Dependencies/engine/.version |
    sed -n 's/^ENGINE_VERSION=//p')"
[[ -n "$ENGINE_VERSION" ]] || fail "ENGINE_VERSION is missing from $PIN_FILE at HEAD"

if [[ "$ENGINE_VERSION" == "unpublished" ]]; then
    echo "note: the engine pin is 'unpublished'; the pin preflight is skipped"
    exit 0
fi

if [[ -z "${GITLINK_SHA:-}" ]]; then
    GITLINK_SHA="$(git -C "$REPO_ROOT" ls-tree HEAD mkxp-z-apple-mobile | awk '{print $3}')"
fi
[[ -n "$GITLINK_SHA" ]] || fail "could not resolve the mkxp-z-apple-mobile gitlink from HEAD"

# Make sure both commits exist in the engine repo. Fetch each one
# shallowly when it is absent (the CI clone starts almost empty).
ensure_commit() {
    local ref="$1"
    shift
    if ! git -C "$ENGINE_REPO_DIR" cat-file -e "$ref^{commit}" 2>/dev/null; then
        git -C "$ENGINE_REPO_DIR" fetch --depth 1 origin "$@" >/dev/null 2>&1 || true
    fi
    git -C "$ENGINE_REPO_DIR" cat-file -e "$ref^{commit}" 2>/dev/null
}

ensure_commit "refs/tags/$ENGINE_VERSION" tag "$ENGINE_VERSION" ||
    fail "the pinned engine tag $ENGINE_VERSION does not exist on the engine origin"
ensure_commit "$GITLINK_SHA" "$GITLINK_SHA" ||
    fail "the submodule commit $GITLINK_SHA is not available in $ENGINE_REPO_DIR or on the engine origin"

# Compare exactly the pathspec that tools/core-fingerprint.sh hashes.
if git -C "$ENGINE_REPO_DIR" diff --quiet "refs/tags/$ENGINE_VERSION" "$GITLINK_SHA" -- \
    ':(glob)src/**/*.c' ':(glob)src/**/*.cpp' ':(glob)src/**/*.mm' ':(glob)src/**/*.h'; then
    echo "OK: engine pin $ENGINE_VERSION matches the submodule core sources"
    exit 0
fi

cat >&2 <<EOF
error: the engine pin is stale. The core sources in the pinned tag
($ENGINE_VERSION) differ from the committed submodule gitlink
(${GITLINK_SHA:0:12}). The fetched libmkxpz-core.a will fail the
fingerprint check in scripts/verify-native-deps.sh.

Publish a fresh engine prebuilt, then update the pin:
  1. git -C mkxp-z-apple-mobile tag <engine-YYYY-MM-DD> $GITLINK_SHA
  2. git -C mkxp-z-apple-mobile push origin <engine-YYYY-MM-DD>
  3. Wait for the engine-artifacts workflow to publish the release.
  4. Set ENGINE_VERSION and ENGINE_SHA256 in ios/Dependencies/engine/.version.
EOF
exit 1
