#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Point each pin at the newest release of its repository: the mkxp-z,
# PSDK and MV/MZ cores, and ANGLE in empo-deps. The sha256 comes from
# the digest that GitHub gives for the release asset.
#
# Usage: scripts/update-pins.sh
# Prints one line for each pin that it changes.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

# update_pin <pin file> <variable prefix> <repository> <tag pattern>
update_pin() {
    local file=$1 prefix=$2 repo=$3 pattern=$4
    local current asset release tag digest
    current=$(sed -n "s/^${prefix}_VERSION=//p" "$file")
    asset=$(sed -n "s/^${prefix}_ASSET=//p" "$file")
    # The API does not list releases by date. empo-deps also has
    # releases that are not ANGLE, so the tag pattern picks the right ones.
    release=$(gh api --paginate "repos/$repo/releases?per_page=100" --jq "
        .[] | select((.draft | not) and (.prerelease | not) and (.tag_name | test(\"$pattern\")))" |
        jq -s 'max_by(.published_at)')
    tag=$(jq -r '.tag_name // empty' <<<"$release")
    if [ -z "$tag" ]; then
        echo "error: $repo has no release that matches $pattern" >&2
        return 1
    fi
    [ "$tag" != "$current" ] || return 0
    digest=$(jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest' <<<"$release")
    case "$digest" in
        sha256:*) ;;
        *)
            echo "error: $repo $tag has no sha256 digest for $asset" >&2
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

update_pin cores/mkxp/.version MKXP_CORE mateo-m/mkxp-z-apple-mobile '^v[0-9]+$'
update_pin cores/psdk/.version PSDK_CORE mateo-m/psdk-apple-mobile '^v[0-9]+$'
update_pin cores/mvmz/.version MVMZ_CORE mateo-m/mvmz-apple-mobile '^v[0-9]+$'
update_pin ios/Dependencies/ANGLE/.version ANGLE mateo-m/empo-deps '^angle-'
