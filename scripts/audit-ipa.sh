#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Checks a Release iphoneos Empo.app or Empo-ios.ipa before it ships.
#
# Usage: scripts/audit-ipa.sh [--version X.Y.Z] [--cores "MkxpCore Psdk30Core"] <Empo.app | Empo-ios.ipa>
#
# --cores names the game cores the bundle must carry, and nothing else.
# Without it the script audits the cores it finds.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_VERSION=""
EXPECTED_CORES=""
INPUT=""

fail() {
    echo "error: $*" >&2
    exit 1
}
# shellcheck source=scripts/lib/app-bundle.sh
source "$REPO_ROOT/scripts/lib/app-bundle.sh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || fail "--version requires a value"
            EXPECTED_VERSION="$2"
            shift 2
            ;;
        --cores)
            [[ $# -ge 2 ]] || fail "--cores requires a value"
            EXPECTED_CORES="$2"
            shift 2
            ;;
        -h | --help)
            echo "usage: $0 [--version X.Y.Z] [--cores \"MkxpCore Psdk30Core\"] <Empo.app | Empo-ios.ipa>"
            exit 0
            ;;
        *)
            [[ -z "$INPUT" ]] || fail "unexpected argument: $1"
            INPUT="$1"
            shift
            ;;
    esac
done

[[ -n "$INPUT" ]] || fail "missing path to Empo.app or .ipa"

TMPDIR=""
cleanup() {
    if [[ -n "$TMPDIR" && -d "$TMPDIR" ]]; then
        rm -rf "$TMPDIR"
    fi
}
trap cleanup EXIT

APP=""
case "$INPUT" in
    *.ipa)
        [[ -f "$INPUT" ]] || fail "ipa not found: $INPUT"
        TMPDIR=$(mktemp -d)
        unzip -q "$INPUT" -d "$TMPDIR"
        APP="$TMPDIR/Payload/Empo.app"
        ;;
    *.app)
        APP="$INPUT"
        ;;
    *)
        fail "expected .app bundle or .ipa, got: $INPUT"
        ;;
esac

[[ -d "$APP" ]] || fail "Empo.app not found in $INPUT"
BIN="$APP/Empo"
[[ -f "$BIN" ]] || fail "Empo binary missing in $APP"

echo "==> auditing $(basename "$INPUT")"

file "$BIN" | grep -Eq "Mach-O 64-bit executable arm64" ||
    fail "Empo is not an arm64 device executable"

has_platform() {
    local path="$1" platform="$2"
    local out
    out=$(otool -l "$path" 2>/dev/null) || return 1
    grep -Eq "platform ${platform}([[:space:]]|$)" <<<"$out"
}

if ! has_platform "$BIN" 2; then
    fail "Empo binary is not device (platform 2)"
fi
if has_platform "$BIN" 7; then
    fail "Empo binary contains simulator objects"
fi

# The engines sit in the core frameworks, not in the app binary. Empo
# opens one with dlopen when the user picks a game, so nothing here names
# them and nm on the app finds no engine symbol.
[[ -d "$APP/Frameworks" ]] || fail "no game core in the app bundle"
PRESENT_CORES=$(find "$APP/Frameworks" -maxdepth 1 -name "*Core.framework" -exec basename {} .framework \; | sort | xargs)
[[ -n "$PRESENT_CORES" ]] || fail "no game core in the app bundle"

contains_word() {
    case " $1 " in
        *" $2 "*) return 0 ;;
    esac
    return 1
}

if [[ -n "$EXPECTED_CORES" ]]; then
    for core in $EXPECTED_CORES; do
        contains_word "$PRESENT_CORES" "$core" ||
            fail "$core.framework missing from the app bundle"
    done
    for core in $PRESENT_CORES; do
        contains_word "$EXPECTED_CORES" "$core" ||
            fail "$core.framework is in the bundle, but --cores does not name it"
    done
fi

audit_core() {
    local core="$1"
    local bin="$APP/Frameworks/$core.framework/$core"
    [[ -f "$bin" ]] || fail "$core.framework has no $core binary"
    has_platform "$bin" 2 || fail "$core is not device (platform 2)"
    ! has_platform "$bin" 7 || fail "$core contains simulator objects"

    # A core exports the GameCore.h names only, so no Ruby and no SDL
    # name escapes it, and a second core cannot bind to its definitions.
    local stray
    stray=$(nm -gU "$bin" | awk '$3 !~ /^_gamecore_/ {print $3}')
    [[ -z "$stray" ]] ||
        fail "$core exports a name that is not _gamecore_*: $(tr '\n' ' ' <<<"$stray")"

    codesign --verify --strict "$bin" 2>/dev/null ||
        fail "$core.framework is not signed (the app's own signature does not reach inside it)"
}

for core in $PRESENT_CORES; do
    audit_core "$core"
done

# Objective-C registers every class by name for the whole process, hidden
# symbol or not. Two binaries with one class name make the class that
# loaded second a dead copy, so each name lives in one binary only.
#
# The PSDK cores count as one owner. Each carries SFML's classes, and no
# two of them open in one process, because a PSDK core can't kill its
# game (PsdkCore.canKillSession).
objc_classes() {
    otool -ov "$1" 2>/dev/null |
        awk '/^Contents of/ {inlist = ($0 ~ /__objc_classlist/)}
            inlist && /^        name +0x[0-9a-f]+ / {print $3}' |
        sort -u
}
CLASS_OWNERS=$(
    objc_classes "$APP/Empo" | sed 's/$/ Empo/'
    for core in $PRESENT_CORES; do
        owner=$core
        [[ "$core" == Psdk*Core ]] && owner=PsdkCores
        objc_classes "$APP/Frameworks/$core.framework/$core" | sed "s/\$/ $owner/"
    done | sort -u
)
SHARED_CLASSES=$(awk '{n[$1]++; owners[$1] = owners[$1] " " $2}
    END {for (c in n) if (n[c] > 1) print c ":" owners[c]}' <<<"$CLASS_OWNERS")
[[ -z "$SHARED_CLASSES" ]] ||
    fail "Objective-C class in more than one binary: $(tr '\n' ';' <<<"$SHARED_CLASSES")"

if contains_word "$PRESENT_CORES" MkxpCore; then
    # One script binding for each Ruby: 1.8, 1.9, and 3.1. See ios/Empo/docs/multi-ruby.md.
    MKXP="$APP/Frameworks/MkxpCore.framework/MkxpCore"
    for ver in 18 19 31; do
        sym="_mkxp_get_script_binding_${ver}"
        nm "$MKXP" 2>/dev/null | awk -v sym="$sym" '$3 == sym {found=1} END {exit !found}' ||
            fail "MkxpCore missing ${sym}"
    done
fi

require_release_bundle_id "$APP/Info.plist"
BUNDLE_ID="$RELEASE_BUNDLE_ID"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Info.plist")

APP_GROUP=$(app_group "$APP/PlugIns/FilesProvider.appex")
has_app_group() {
    codesign -d --entitlements - --xml "$1" 2>/dev/null | grep -qF "<string>$APP_GROUP</string>"
}
has_app_group "$APP" || fail "Empo is not signed with the app group $APP_GROUP"
for extension in "$APP"/Extensions/*.appex "$APP"/PlugIns/*.appex; do
    [[ -d "$extension" ]] || continue
    name=$(basename "$extension")
    id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$extension/Info.plist")
    [[ "$id" == "$BUNDLE_ID".* ]] || fail "$name bundle id $id is not under $BUNDLE_ID"
    codesign --verify --strict "$extension" 2>/dev/null || fail "$name is not signed"
    has_app_group "$extension" || fail "$name is not signed with the app group $APP_GROUP"
done
GAME_PROCESS="$APP/Extensions/GameProcess.appex"
if [[ -d "$GAME_PROCESS" ]]; then
    POINT=$(/usr/libexec/PlistBuddy -c "Print :EXAppExtensionAttributes:EXExtensionPointIdentifier" "$GAME_PROCESS/Info.plist")
    [[ "$POINT" == "$BUNDLE_ID.game-process" ]] ||
        fail "GameProcess.appex extension point $POINT != $BUNDLE_ID.game-process"
    /usr/libexec/PlistBuddy -c "Print :$BUNDLE_ID.game-process" "$APP/Extensions/Empo.appexpt" >/dev/null 2>&1 ||
        fail "Extensions/Empo.appexpt does not define $BUNDLE_ID.game-process"
fi

if [[ -n "$EXPECTED_VERSION" && "$VERSION" != "$EXPECTED_VERSION" ]]; then
    fail "Info.plist version $VERSION != expected $EXPECTED_VERSION"
fi

HEAD_COMMIT=$(git -C "$REPO_ROOT" rev-parse HEAD)

# The Release optimiser folds the whole line into one string, so the
# dirty marker arrives on the commit line and not on a line of its own.
# Read the line first, then test it. A grep that finds nothing inside a
# command substitution fails the assignment, and set -e would end the
# script with no word about why.
GIT_LINE=$(grep -m1 -E '^commit: ' < <(strings "$BIN") || true)
[[ -n "$GIT_LINE" ]] || fail "embedded GitInfo commit not found in binary"
[[ "$GIT_LINE" != *"(dirty)"* ]] ||
    fail "binary embeds a dirty GitInfo marker ($GIT_LINE)"

require_update_check "$BIN"

EMBEDDED_COMMIT=$(awk '{print $2}' <<<"$GIT_LINE")
[[ ${#EMBEDDED_COMMIT} -ge 12 && "$HEAD_COMMIT" == "$EMBEDDED_COMMIT"* ]] ||
    fail "embedded commit $EMBEDDED_COMMIT is not HEAD $HEAD_COMMIT"

SIZE=$(stat -f%z "$BIN")
# The app binary is the launcher alone now, a few MB. The engines sit in
# the cores, which are the large ones.
[[ "$SIZE" -ge 2000000 ]] || fail "Empo binary suspiciously small (${SIZE} bytes)"

CORE_SIZES=""
for core in $PRESENT_CORES; do
    core_size=$(stat -f%z "$APP/Frameworks/$core.framework/$core")
    case "$core" in
        MkxpCore) min=25000000 ;;
        Psdk*Core) min=15000000 ;;
        # A web view host with no engine inside.
        MvmzCore) min=50000 ;;
        *) fail "$core has no size floor in this script" ;;
    esac
    [[ "$core_size" -ge "$min" ]] || fail "$core suspiciously small (${core_size} bytes)"
    CORE_SIZES="${CORE_SIZES:+$CORE_SIZES, }$core ${core_size} bytes"
done

echo "OK: release artifact audit passed"
echo "    bundle: $BUNDLE_ID"
echo "    version: $VERSION ($BUILD)"
echo "    commit: $EMBEDDED_COMMIT"
echo "    binary: ${SIZE} bytes"
echo "    cores: $CORE_SIZES"
