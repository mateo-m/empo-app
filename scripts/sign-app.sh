#!/usr/bin/env bash
# Ad-hoc sign an Empo.app that Xcode built with CODE_SIGNING_ALLOWED=NO,
# with the entitlements of each bundle. scripts/release.sh, step 6, says
# why a release carries this signature.
#
# Usage: scripts/sign-app.sh path/to/Empo.app
set -euo pipefail

APP="$1"
PROJECT_DIR="$(cd "$(dirname "$0")/../ios/Empo" && pwd)"
ENTITLEMENTS_DIR="$(mktemp -d)"
trap 'rm -rf "$ENTITLEMENTS_DIR"' EXIT

# The entitlements files name the app group as $(EMPO_APP_GROUP), and
# only a signed Xcode build fills it in.
APP_GROUP="$(/usr/libexec/PlistBuddy -c "Print :EmpoAppGroup" "$APP/Info.plist")"

sign() {
    local bundle="$1" entitlements
    entitlements="$ENTITLEMENTS_DIR/$(basename "$1").entitlements"
    sed "s/\$(EMPO_APP_GROUP)/$APP_GROUP/" "$2" >"$entitlements"
    codesign --force --sign - --timestamp=none \
        --generate-entitlement-der \
        --entitlements "$entitlements" \
        "$bundle"
}

# Inside out. A nested bundle carries its own signature, and signing
# the app does not reach inside it.
for FRAMEWORK in "$APP"/Frameworks/*.framework; do
    [[ -d "$FRAMEWORK" ]] || continue
    codesign --force --sign - --timestamp=none "$FRAMEWORK"
done
for EXTENSION in "$APP"/Extensions/*.appex "$APP"/PlugIns/*.appex; do
    [[ -d "$EXTENSION" ]] || continue
    NAME="$(basename "$EXTENSION" .appex)"
    sign "$EXTENSION" "$PROJECT_DIR/$NAME/$NAME.entitlements"
done
sign "$APP" "$PROJECT_DIR/Empo.entitlements"
