#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Point each core pin at the newest release of its repository, and the
# ANGLE pin at the ANGLE release that the mkxp-z core names. The sha256
# comes from the digest that GitHub gives for the release asset.
#
# Usage: scripts/update-pins.sh
# Prints one line for each pin that it changes. When a pin cannot
# change, the script still does the others, then exits with 1.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

# update_pin <pin file> <variable prefix> <repository> <tag pattern> [tag]
# With a tag, the pin moves to that release, not to the newest one.
update_pin() {
    local file=$1 prefix=$2 repo=$3 pattern=$4 want=${5:-}
    local current asset release tag digest
    current=$(sed -n "s/^${prefix}_VERSION=//p" "$file")
    asset=$(sed -n "s/^${prefix}_ASSET=//p" "$file")
    if [ -n "$want" ]; then
        release=$(gh api "repos/$repo/releases/tags/$want") || {
            echo "error: $repo has no release $want" >&2
            return 1
        }
    else
        # The API does not list releases by date. empo-deps also has
        # releases that are not ANGLE, so the tag pattern picks the
        # right ones.
        release=$(gh api --paginate "repos/$repo/releases?per_page=100" --jq "
            .[] | select((.draft | not) and (.prerelease | not) and (.tag_name | test(\"$pattern\")))" |
            jq -s 'max_by(.published_at)')
    fi
    tag=$(jq -r '.tag_name // empty' <<<"$release")
    if [ -z "$tag" ]; then
        echo "error: $repo has no release that matches $pattern" >&2
        return 1
    fi
    [ "$tag" != "$current" ] || return 0
    if ! jq -e --arg asset "$asset" 'any(.assets[]; .name == $asset)' <<<"$release" >/dev/null; then
        echo "error: $repo $tag has no asset $asset. Set ${prefix}_ASSET in $file by hand." >&2
        return 1
    fi
    digest=$(jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest // empty' <<<"$release")
    case "$digest" in
        sha256:*) ;;
        *)
            echo "error: GitHub gives no sha256 digest for $asset in $repo $tag" >&2
            return 1
            ;;
    esac
    sed -i.bak \
        -e "s/^${prefix}_VERSION=.*/${prefix}_VERSION=$tag/" \
        -e "s/^${prefix}_SHA256=.*/${prefix}_SHA256=${digest#sha256:}/" \
        "$file"
    rm "$file.bak"
    echo "$repo: $current to $tag"
}

FAILED=0
update_pin cores/mkxp/.version MKXP_CORE mateo-m/mkxp-z-apple-mobile '^v[0-9]+$' || FAILED=1
update_pin cores/psdk/.version PSDK_CORE mateo-m/psdk-apple-mobile '^v[0-9]+$' || FAILED=1
update_pin cores/mvmz/.version MVMZ_CORE mateo-m/mvmz-apple-mobile '^v[0-9]+$' || FAILED=1

# The mkxp-z core compiles against one ANGLE release, and the MANIFEST
# at the start of its archive names it. cores/mkxp/build-framework-ios.sh
# stops the build when the ANGLE pin names another one.
# shellcheck disable=SC1091
. cores/mkxp/.version
# tar can stop reading once it has MANIFEST, and curl then fails, so
# only an empty result counts as a failure.
ANGLE_TAG=$(curl -fsL "https://github.com/mateo-m/mkxp-z-apple-mobile/releases/download/$MKXP_CORE_VERSION/$MKXP_CORE_ASSET" |
    tar -xzOf - MANIFEST | sed -n 's/^angle=//p') || true
if [ -n "$ANGLE_TAG" ]; then
    update_pin ios/Dependencies/ANGLE/.version ANGLE mateo-m/empo-deps '^angle-' "$ANGLE_TAG" || FAILED=1
else
    echo "error: could not read the ANGLE release from the MANIFEST of mkxp-z $MKXP_CORE_VERSION" >&2
    FAILED=1
fi

exit "$FAILED"
