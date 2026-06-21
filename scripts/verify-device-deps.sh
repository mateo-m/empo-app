#!/usr/bin/env bash
# Fail fast if iphoneos dependency artifacts are missing, contaminated, or broken.
# For full per-SDK checks, use scripts/verify-native-deps.sh directly.
#
# Usage: scripts/verify-device-deps.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM_NAME=iphoneos "$REPO_ROOT/scripts/verify-native-deps.sh"

SIM_LIB="$REPO_ROOT/ios/Dependencies/build-iphonesimulator-arm64/lib"
LIB="$REPO_ROOT/ios/Dependencies/build-iphoneos-arm64/lib"

# Cross-tree freshness: a newer simulator ext archive usually means a partial
# simulator rebuild contaminated shared Ruby source state.
if [[ -f "$SIM_LIB/libruby.3.1-ext.a" && -f "$LIB/libruby.3.1-ext.a" ]]; then
    if [[ "$SIM_LIB/libruby.3.1-ext.a" -nt "$LIB/libruby.3.1-ext.a" ]]; then
        echo "error: simulator libruby.3.1-ext.a is newer than device — rebuild both trees" >&2
        echo "hint: scripts/rebuild-all-native-deps.sh" >&2
        exit 1
    fi
fi
