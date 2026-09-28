#!/bin/sh
# Verify ios dependency pins resolve to published releases: ANGLE in
# empo-deps, the mkxp-z core in mkxp-z-apple-mobile, the PSDK core in
# psdk-apple-mobile, the MV/MZ core in mvmz-apple-mobile.
#
# Usage:
#   scripts/verify-empo-deps-pins.sh
#   REQUIRE_PUBLISHED=1 scripts/verify-empo-deps-pins.sh
#
# REQUIRE_PUBLISHED=1 fails when a pin is still "unpublished". Use it
# in release.sh and on version tags.

set -e

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

DEPS_REPO="${EMPO_DEPS_REPO:-mateo-m/empo-deps}"
ANGLE_VERSION_FILE="$REPO_ROOT/ios/Dependencies/ANGLE/.version"
MKXP_VERSION_FILE="$REPO_ROOT/cores/mkxp/.version"
PSDK_VERSION_FILE="$REPO_ROOT/cores/psdk/.version"
MVMZ_VERSION_FILE="$REPO_ROOT/cores/mvmz/.version"

die() {
    printf 'verify-empo-deps-pins: %s\n' "$1" >&2
    exit 1
}

require_gh() {
    command -v gh >/dev/null 2>&1 ||
        die "gh CLI is required (brew install gh && gh auth login)"
}

release_exists() {
    repo=$1
    tag=$2
    gh release view "$tag" --repo "$repo" >/dev/null 2>&1
}

asset_sha256() {
    repo=$1
    tag=$2
    asset=$3
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/empo-deps-pin.XXXXXX")
    if ! gh release download "$tag" --repo "$repo" --pattern "$asset" --dir "$tmpdir" >/dev/null 2>&1; then
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
    repo=$6

    [ -f "$version_file" ] || die "$label: missing $version_file"

    # shellcheck disable=SC1090
    . "$version_file"

    eval "version=\${$version_var:-}"
    eval "expected_sha=\${$sha_var:-}"

    [ -n "$version" ] || die "$label: $version_var unset in $version_file"

    if [ "$version" = "unpublished" ]; then
        if [ "${REQUIRE_PUBLISHED:-0}" = "1" ]; then
            die "$label: $version_var=unpublished (publish to $repo first)"
        fi
        printf 'verify-empo-deps-pins: %s unpublished (skipped)\n' "$label"
        return 0
    fi

    require_gh
    release_exists "$repo" "$version" ||
        die "$label: release $repo@$version not found"

    if [ -n "$expected_sha" ]; then
        actual_sha=$(asset_sha256 "$repo" "$version" "$asset_name") ||
            die "$label: could not download $asset_name from $version"
        [ "$actual_sha" = "$expected_sha" ] ||
            die "$label: sha256 mismatch for $asset_name@$version"
    else
        printf 'verify-empo-deps-pins: warning: %s empty, release exists but checksum not verified\n' \
            "$sha_var" >&2
    fi

    printf 'verify-empo-deps-pins: %s OK (%s)\n' "$label" "$version"
}

verify_pin_file "ANGLE" "$ANGLE_VERSION_FILE" ANGLE_VERSION ANGLE_SHA256 "angle-ios-prebuilt.tar.gz" "$DEPS_REPO"
verify_pin_file "mkxp-z core" "$MKXP_VERSION_FILE" MKXP_CORE_VERSION MKXP_CORE_SHA256 "mkxp-z-ios.tar.gz" mateo-m/mkxp-z-apple-mobile
verify_pin_file "PSDK core" "$PSDK_VERSION_FILE" PSDK_CORE_VERSION PSDK_CORE_SHA256 "psdk-ios.tar.gz" mateo-m/psdk-apple-mobile
verify_pin_file "MV/MZ core" "$MVMZ_VERSION_FILE" MVMZ_CORE_VERSION MVMZ_CORE_SHA256 "mvmz-ios.tar.gz" mateo-m/mvmz-apple-mobile

printf 'verify-empo-deps-pins: all checks passed\n'
