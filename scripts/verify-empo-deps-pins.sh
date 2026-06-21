#!/bin/sh
# Verify ios dependency pins resolve to published empo-deps releases.
#
# Usage:
#   scripts/verify-empo-deps-pins.sh
#   REQUIRE_PUBLISHED=1 scripts/verify-empo-deps-pins.sh
#
# REQUIRE_PUBLISHED=1 fails when native deps are still pinned to
# "unpublished". Use in release.sh and on version tags.

set -e

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

DEPS_REPO="${EMPO_DEPS_REPO:-mateo-m/empo-deps}"
ANGLE_VERSION_FILE="$REPO_ROOT/ios/Dependencies/ANGLE/.version"
NATIVE_VERSION_FILE="$REPO_ROOT/ios/Dependencies/native/.version"

die() {
    printf 'verify-empo-deps-pins: %s\n' "$1" >&2
    exit 1
}

require_gh() {
    command -v gh >/dev/null 2>&1 ||
        die "gh CLI is required (brew install gh && gh auth login)"
}

release_exists() {
    tag=$1
    gh release view "$tag" --repo "$DEPS_REPO" >/dev/null 2>&1
}

asset_sha256() {
    tag=$1
    asset=$2
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/empo-deps-pin.XXXXXX")
    if ! gh release download "$tag" --repo "$DEPS_REPO" --pattern "$asset" --dir "$tmpdir" >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        return 1
    fi
    sha=$(shasum -a 256 "$tmpdir/$asset" | awk '{print $1}') || {
        rm -rf "$tmpdir"
        return 1
    }
    rm -rf "$tmpdir"
    printf '%s\n' "$sha"
}

verify_pin_file() {
    label=$1
    version_file=$2
    version_var=$3
    sha_var=$4
    asset_name=$5

    [ -f "$version_file" ] || die "$label: missing $version_file"

    # shellcheck disable=SC1090
    . "$version_file"

    eval "version=\${$version_var:-}"
    eval "expected_sha=\${$sha_var:-}"

    [ -n "$version" ] || die "$label: $version_var unset in $version_file"

    if [ "$version" = "unpublished" ]; then
        if [ "${REQUIRE_PUBLISHED:-0}" = "1" ]; then
            die "$label: $version_var=unpublished (publish to $DEPS_REPO first)"
        fi
        printf 'verify-empo-deps-pins: %s unpublished (skipped)\n' "$label"
        return 0
    fi

    require_gh
    release_exists "$version" ||
        die "$label: release $DEPS_REPO@$version not found"

    if [ -n "$expected_sha" ]; then
        actual_sha=$(asset_sha256 "$version" "$asset_name") ||
            die "$label: could not download $asset_name from $version"
        [ "$actual_sha" = "$expected_sha" ] ||
            die "$label: sha256 mismatch for $asset_name@$version"
    else
        printf 'verify-empo-deps-pins: warning: %s empty; release exists but checksum not verified\n' \
            "$sha_var" >&2
    fi

    printf 'verify-empo-deps-pins: %s OK (%s)\n' "$label" "$version"
}

verify_pin_file "ANGLE" "$ANGLE_VERSION_FILE" ANGLE_VERSION ANGLE_SHA256 "angle-ios-prebuilt.tar.gz"
verify_pin_file "native" "$NATIVE_VERSION_FILE" NATIVE_DEPS_VERSION NATIVE_DEPS_SHA256 "native-ios-prebuilt.tar.gz"

printf 'verify-empo-deps-pins: all checks passed\n'
