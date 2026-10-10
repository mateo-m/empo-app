#!/usr/bin/env bash
# Ad-hoc sign an Empo.app that Xcode built with CODE_SIGNING_ALLOWED=NO.
# scripts/release.sh, step 6, says why a release carries this signature.
#
# Usage: scripts/sign-app.sh path/to/Empo.app
set -euo pipefail

APP="$1"
PROJECT_DIR="$(cd "$(dirname "$0")/../ios/Empo" && pwd)"
ENTITLEMENTS="$(mktemp)"
trap 'rm -f "$ENTITLEMENTS"' EXIT

# The app and its extensions share one entitlements file. It names the
# app group as $(EMPO_APP_GROUP), and only a signed Xcode build fills it
# in.
APP_GROUP="$(/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionFileProviderDocumentGroup" "$APP/PlugIns/FilesProvider.appex/Info.plist")"
sed "s/\$(EMPO_APP_GROUP)/$APP_GROUP/" "$PROJECT_DIR/Empo.entitlements" >"$ENTITLEMENTS"

# Inside out. A nested bundle carries its own signature, and signing
# the app does not reach inside it.
for FRAMEWORK in "$APP"/Frameworks/*.framework; do
    [[ -d "$FRAMEWORK" ]] || continue
    codesign --force --sign - --timestamp=none "$FRAMEWORK"
done
for BUNDLE in "$APP"/Extensions/*.appex "$APP"/PlugIns/*.appex "$APP"; do
    [[ -d "$BUNDLE" ]] || continue
    codesign --force --sign - --timestamp=none \
        --generate-entitlement-der \
        --entitlements "$ENTITLEMENTS" \
        "$BUNDLE"
done
