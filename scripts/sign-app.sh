#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Ad hoc signs an Empo.app that Xcode built with CODE_SIGNING_ALLOWED=NO.
# iOS does not trust this signature, and each sideloading tool signs the
# app again. But the tools copy the entitlements of this signature. With
# no entitlements, some tools write an incomplete set, and parts of the
# app stop working.
#
# Usage: scripts/sign-app.sh path/to/Empo.app
set -euo pipefail

APP="$1"
PROJECT_DIR="$(cd "$(dirname "$0")/../ios/Empo" && pwd)"
# shellcheck source=scripts/lib/app-bundle.sh
source "$(dirname "$0")/lib/app-bundle.sh"
ENTITLEMENTS="$(mktemp)"
trap 'rm -f "$ENTITLEMENTS"' EXIT

APP_GROUP="$(app_group "$APP/PlugIns/FilesProvider.appex")"
sed "s/\$(EMPO_APP_GROUP)/$APP_GROUP/" "$PROJECT_DIR/Empo.entitlements" >"$ENTITLEMENTS"

# Inside out. A nested bundle carries its own signature, and signing
# the app does not reach inside it.
# iOS 15 and later read some entitlements only from the DER form.
# Do not add --options=runtime. On iOS, dyld then refuses to load the
# app, and the app opens to a black screen.
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
