#!/usr/bin/env bash
# Print the AltStore update text for one version: the What's new items
# that ship in it, then one line when its changelog section has bug
# fixes. AltStore shows this text as plain text, so it has no Markdown.
#
# Usage: scripts/whats-new-notes.sh <version> [changelog-path]
set -euo pipefail

VERSION="${1:?usage: $0 <version> [changelog-path]}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG_PATH="${2:-$ROOT/CHANGELOG.md}"

items=$(jq -r --arg v "$VERSION" \
    '[.[] | select(.appVersion == $v) | .items[] | "\(.title)\n\(.detail)"] | join("\n\n")' \
    "$ROOT/ios/Empo/src/Library/WhatsNew.json")

fixes=""
if "$ROOT/scripts/extract-changelog.sh" "$VERSION" "$CHANGELOG_PATH" | grep -q '^### Bug Fixes'; then
    if [[ -n "$items" ]]; then fixes="This update also fixes some bugs."; else fixes="This update fixes some bugs."; fi
fi

if [[ -n "$items" && -n "$fixes" ]]; then
    printf '%s\n\n%s' "$items" "$fixes"
else
    printf '%s%s' "$items" "$fixes"
fi
