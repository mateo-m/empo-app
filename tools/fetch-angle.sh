#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Hydrate ios/Dependencies/ANGLE/ with the prebuilt static libs +
# headers from the empo-deps repo.
#
# - Reads version + expected sha256 from ios/Dependencies/ANGLE/.version
# - Skips work when a stamp file matches the requested version and the
#   binaries are already on disk
# - Downloads the release asset with curl. empo-deps is public, so no
#   login or token is needed.
# - Verifies the downloaded tarball's sha256 before extracting

set -euo pipefail

# When the script runs as an Xcode build phase, anchor paths off
# PROJECT_DIR. For manual runs, fall back to the script's own location.
if [ -n "${PROJECT_DIR:-}" ]; then
    REPO_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"
else
    REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

ANGLE_DIR="$REPO_ROOT/ios/Dependencies/ANGLE"
VERSION_FILE="$ANGLE_DIR/.version"
STAMP="$ANGLE_DIR/.fetched-version"
DEPS_REPO="${EMPO_DEPS_REPO:-mateo-m/empo-deps}"

if [ ! -f "$VERSION_FILE" ]; then
    echo "fetch-angle: $VERSION_FILE missing; cannot resolve ANGLE version" >&2
    exit 1
fi

# Xcode and a script can run this at the same time. lockf runs one at a
# time, and the second then finds ANGLE in place.
if [ -z "${FETCH_ANGLE_LOCKED:-}" ]; then
    FETCH_ANGLE_LOCKED=1 exec lockf -k "$ANGLE_DIR.lock" "$0" "$@"
fi

# shellcheck disable=SC1090
. "$VERSION_FILE" # sets ANGLE_VERSION, ANGLE_SHA256 and ANGLE_ASSET

if [ -z "${ANGLE_VERSION:-}" ] || [ -z "${ANGLE_SHA256:-}" ] || [ -z "${ANGLE_ASSET:-}" ]; then
    echo "fetch-angle: $VERSION_FILE must define ANGLE_VERSION, ANGLE_SHA256 and ANGLE_ASSET" >&2
    exit 1
fi

# When the tree is hydrated and the stamp matches the pinned
# version, there is nothing to do.
if [ -f "$STAMP" ] &&
    [ "$(cat "$STAMP" 2>/dev/null)" = "$ANGLE_VERSION" ] &&
    [ -f "$ANGLE_DIR/iphoneos/lib/libANGLE_static.a" ] &&
    [ -f "$ANGLE_DIR/iphonesimulator/lib/libANGLE_static.a" ] &&
    [ -f "$ANGLE_DIR/macosx/lib/libANGLE_static.a" ]; then
    exit 0
fi

# The work folder is next to ANGLE_DIR, on the same disk, so mv only
# renames. A run that was killed leaves its work folder, and the lock
# makes sure that no other run uses one now.
rm -rf "$ANGLE_DIR".??????
TMPDIR="$(mktemp -d "$ANGLE_DIR.XXXXXX")"
trap 'rm -rf "$TMPDIR"' EXIT

echo "fetch-angle: hydrating $ANGLE_VERSION from $DEPS_REPO"

if ! curl -fL --retry 3 -o "$TMPDIR/$ANGLE_ASSET" \
    "https://github.com/$DEPS_REPO/releases/download/$ANGLE_VERSION/$ANGLE_ASSET"; then
    echo "fetch-angle: download failed for $DEPS_REPO@$ANGLE_VERSION" >&2
    exit 1
fi

ACTUAL_SHA="$(shasum -a 256 "$TMPDIR/$ANGLE_ASSET" | awk '{print $1}')"
if [ "$ACTUAL_SHA" != "$ANGLE_SHA256" ]; then
    echo "fetch-angle: sha256 mismatch" >&2
    echo "  expected: $ANGLE_SHA256" >&2
    echo "  actual:   $ACTUAL_SHA" >&2
    exit 1
fi

# The tarball holds <sdk>/include and <sdk>/lib for iphoneos,
# iphonesimulator and macosx, relative to ANGLE_DIR. ANGLE_DIR also
# holds the tracked .version, so each SDK folder is replaced on its own.
# The stamp goes first, so a run that stops halfway is not trusted.
mkdir "$TMPDIR/angle"
tar -xzf "$TMPDIR/$ANGLE_ASSET" -C "$TMPDIR/angle"
rm -f "$STAMP"
for SDK_DIR in "$TMPDIR/angle"/*/; do
    SDK="$(basename "$SDK_DIR")"
    rm -rf "${ANGLE_DIR:?}/$SDK"
    mv "$SDK_DIR" "$ANGLE_DIR/$SDK"
done

echo "$ANGLE_VERSION" >"$STAMP"
echo "fetch-angle: hydrated $ANGLE_VERSION ($ANGLE_SHA256)"
