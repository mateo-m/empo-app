# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Checks that the iPhone release and the Mac release share.
# Source this file. require_release_bundle_id calls the fail function of the
# caller.

RELEASE_BUNDLE_ID="sh.mateo.empo"

# The entitlements name the app group as $(EMPO_APP_GROUP), and only a
# signed Xcode build fills it in. The Files extension has the value.
app_group() {
    /usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionFileProviderDocumentGroup" "$1/Info.plist"
}

require_release_bundle_id() {
    local id
    id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1")
    [[ "$id" == "$RELEASE_BUNDLE_ID" ]] || fail "unexpected bundle id: $id (expected $RELEASE_BUNDLE_ID)"
}

# Only a build with Sideload.xcconfig has the GitHub update check.
# grep -c reads to the end. grep -q stops at the first match, and
# strings then fails with "failed to flush output".
require_update_check() {
    [[ $(strings "$1" | grep -c "api.github.com/repos") -gt 0 ]] ||
        fail "the app has no update check. Build it with -xcconfig ios/Empo/Sideload.xcconfig"
}
