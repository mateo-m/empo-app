#!/usr/bin/env bash
# Rebuild BOTH iphoneos and iphonesimulator native dep trees sequentially.
# Run once after a dep version bump — not when switching Xcode destinations.
#
# Usage: scripts/rebuild-all-native-deps.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> rebuilding device (iphoneos) native deps"
"$REPO_ROOT/scripts/rebuild-device-deps.sh"

echo ""
echo "==> rebuilding simulator (iphonesimulator) native deps"
"$REPO_ROOT/scripts/rebuild-simulator-deps.sh"

echo ""
echo "==> both trees healthy; safe to switch Xcode destinations without make"
echo "To publish for the team: tools/package-native-deps.sh <release-tag>"
