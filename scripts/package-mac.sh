#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Build the Release Mac app, check it, and pack it into a disk image.
# The Release workflow and scripts/release.sh both run this script.
#
# Usage: scripts/package-mac.sh <version>
# EMPO_CORES in the environment ships only the cores it names.
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
DERIVED_DATA="$OUT/DerivedData"
APP="$DERIVED_DATA/Build/Products/Release/Empo.app"
# A fixed name, so releases/latest/download/Empo-mac.dmg always
# points to the newest one.
DMG="$OUT/Empo-mac.dmg"

fail() {
    echo "error: $*" >&2
    exit 1
}

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
    ${EMPO_CORES:+"EMPO_CORES=$EMPO_CORES"} \
    build 2>&1 | grep -E "^(\*\* BUILD|error:)" >&2
[[ -d "$APP" ]] || fail "build failed: $APP not found"

PLAYER="$APP/Contents/Helpers/Empo Player.app"
[[ -d "$PLAYER" ]] || fail "Empo Player.app missing from Contents/Helpers"

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[[ "$BUNDLE_ID" == "sh.mateo.empo" ]] || fail "unexpected bundle id: $BUNDLE_ID"
[[ "$APP_VERSION" == "$VERSION" ]] || fail "Info.plist version $APP_VERSION != $VERSION"

CORES=$(find "$APP/Contents/Frameworks" -maxdepth 1 -name "*Core.framework" -exec basename {} .framework \; | sort | xargs)
[[ -n "$CORES" ]] || fail "no game core in Contents/Frameworks"

codesign --verify --deep --strict "$APP" || fail "the app signature is not valid"

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
hdiutil create -quiet -volname Empo -srcfolder "$STAGE" -format UDZO -ov "$DMG"
rm -rf "$STAGE"

echo "$DMG"
