#!/usr/bin/env bash
# Print the CHANGELOG.md section for one version (without its heading).
# Shared by scripts/release.sh and .github/workflows/release.yml so the
# GitHub release, AltStore description, and committed changelog always
# carry identical text.
#
# Usage: scripts/extract-changelog.sh <version> [changelog-path]
set -euo pipefail

VERSION="${1:-}"
CHANGELOG_PATH="${2:-"$(cd "$(dirname "$0")/.." && pwd)/CHANGELOG.md"}"

if [[ -z "$VERSION" ]]; then
    echo "usage: $0 <version> [changelog-path]" >&2
    exit 2
fi
if [[ ! -f "$CHANGELOG_PATH" ]]; then
    echo "error: changelog not found at $CHANGELOG_PATH" >&2
    exit 1
fi

SECTION=$(VERSION="$VERSION" perl -0ne '
    $version = quotemeta($ENV{VERSION});
    if (/^## $version - .*?\n\n(.*?)(?=^## \d+\.\d+\.\d+ - |\z)/ms) {
        print $1;
        exit;
    }
' "$CHANGELOG_PATH")

if [[ -z "${SECTION//[$' \t\r\n']/}" ]]; then
    echo "error: no v$VERSION section found in $CHANGELOG_PATH" >&2
    exit 1
fi

printf '%s' "$SECTION"
