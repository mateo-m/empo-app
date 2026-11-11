#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Builds the Release Mac app, checks it, and packs it into a disk image.
#
# Usage: scripts/package-mac.sh <version>
# EMPO_CORES in the environment ships only the cores it names.
# SENTRY_DSN in the environment turns on the error reports.
# EMPO_MAC_DERIVED_DATA in the environment keeps the build data in that
# folder, so the next build compiles only what changed. Without it,
# each build starts clean.
# Prints the path of the disk image on its last line.
#
# The app has an ad hoc signature only (no Developer ID, no
# notarization), so Gatekeeper refuses it on the first open. The
# install guide in docs/install.mdx tells users how to open it.
set -euo pipefail

VERSION="${1:?usage: $0 <version>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$REPO_ROOT/ios/Empo"
OUT="$REPO_ROOT/build/mac-release"
DERIVED_DATA="${EMPO_MAC_DERIVED_DATA:-$OUT/DerivedData}"
APP="$DERIVED_DATA/Build/Products/Release/Empo.app"
# A fixed name, so releases/latest/download/Empo-mac.dmg always
# points to the newest one.
DMG="$OUT/Empo-mac.dmg"

fail() {
    echo "error: $*" >&2
    exit 1
}
# shellcheck source=scripts/lib/app-bundle.sh
source "$REPO_ROOT/scripts/lib/app-bundle.sh"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> building the Mac app" >&2
# Send the build log to stderr: the caller reads the disk image path
# from stdout. With pipefail, a failed build stops the script here.
xcodebuild \
    -project "$PROJECT_DIR/Empo.xcodeproj" \
    -scheme EmpoMac \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -xcconfig "$PROJECT_DIR/Sideload.xcconfig" \
    ${EMPO_CORES:+"EMPO_CORES=$EMPO_CORES"} \
    ${SENTRY_DSN:+SENTRY_DSN="$SENTRY_DSN"} \
    build 2>&1 | grep -E "^(\*\* BUILD|error:)" >&2
[[ -d "$APP" ]] || fail "build failed: $APP not found"

PLAYER="$APP/Contents/Helpers/Empo Player.app"
[[ -d "$PLAYER" ]] || fail "Empo Player.app missing from Contents/Helpers"

require_release_bundle_id "$APP/Contents/Info.plist"
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[[ "$APP_VERSION" == "$VERSION" ]] || fail "Info.plist version $APP_VERSION != $VERSION"

CORES=$(find "$APP/Contents/Frameworks" -maxdepth 1 -name "*Core.framework" -exec basename {} .framework \; | sort | xargs)
[[ -n "$CORES" ]] || fail "no game core in Contents/Frameworks"

codesign --verify --deep --strict "$APP" || fail "the app signature is not valid"

require_update_check "$APP/Contents/MacOS/Empo"

# A user plays a game only when Empo Player opens its core. The signing,
# the entitlements and the sandbox all decide that, and only a run of
# the signed app shows the result.
echo "==> opening each core in Empo Player" >&2
"$APP/Contents/MacOS/Empo" --check-cores >&2 || fail "Empo Player cannot open every core, so games cannot start"

echo "==> packing $(basename "$DMG") (cores: $CORES)" >&2
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Empo.app"
ln -s /Applications "$STAGE/Applications"
# diskutil writes its progress to stderr on one line with no line end,
# so show its output only when it fails.
if ! DISKUTIL_LOG=$(diskutil image create from --format UDZO --volumeName Empo "$STAGE" "$DMG" 2>&1); then
    echo "$DISKUTIL_LOG" >&2
    fail "diskutil could not create $(basename "$DMG")"
fi
rm -rf "$STAGE"

echo "$DMG"
