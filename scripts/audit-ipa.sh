#!/usr/bin/env bash
# Verify a Release iphoneos Empo.app or unsigned .ipa before publishing.
#
# Usage:
#   scripts/audit-ipa.sh path/to/Empo.app
#   scripts/audit-ipa.sh [--version X.Y.Z] path/to/Empo-unsigned.ipa
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_VERSION=""
INPUT=""

fail() {
    echo "error: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || fail "--version requires a value"
            EXPECTED_VERSION="$2"
            shift 2
            ;;
        -h | --help)
            echo "usage: $0 [--version X.Y.Z] <Empo.app | Empo-unsigned.ipa>"
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

# The engine is in MkxpCore.framework, not in the app binary. Empo
# opens it with dlopen when the user picks a game, so nothing here
# names it and nm on the app finds no engine symbol.
CORE="$APP/Frameworks/MkxpCore.framework/MkxpCore"
[[ -f "$CORE" ]] || fail "MkxpCore.framework missing from the app bundle"
has_platform "$CORE" 2 || fail "MkxpCore is not device (platform 2)"
! has_platform "$CORE" 7 || fail "MkxpCore contains simulator objects"

for ver in 18 19 31; do
    sym="_mkxp_get_script_binding_${ver}"
    nm "$CORE" 2>/dev/null | awk -v sym="$sym" '$3 == sym {found=1} END {exit !found}' ||
        fail "MkxpCore missing ${sym}"
done

# The whole point of the framework: no Ruby and no SDL name escapes it,
# so a second core cannot bind to this one's definitions.
nm -gU "$CORE" | awk '$3 !~ /^_mkxp_/ {print $3}' | grep -q . &&
    fail "MkxpCore exports a name that is not mkxp_*"

codesign --verify --strict "$CORE" 2>/dev/null ||
    fail "MkxpCore.framework is not signed (the app's own signature does not reach inside it)"

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Info.plist")

[[ "$BUNDLE_ID" == "sh.mateo.empo" ]] ||
    fail "unexpected bundle id: $BUNDLE_ID (expected sh.mateo.empo for release IPA)"

if [[ -n "$EXPECTED_VERSION" && "$VERSION" != "$EXPECTED_VERSION" ]]; then
    fail "Info.plist version $VERSION != expected $EXPECTED_VERSION"
fi

HEAD_COMMIT=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
EMBEDDED_COMMIT=$(grep -m1 -E '^commit: [0-9a-f]+$' < <(strings "$BIN") | awk '{print $2}')
[[ -n "$EMBEDDED_COMMIT" ]] || fail "embedded GitInfo commit not found in binary"
[[ "$EMBEDDED_COMMIT" == "$HEAD_COMMIT" ]] ||
    fail "embedded commit $EMBEDDED_COMMIT != HEAD $HEAD_COMMIT"

if grep -Eq ' \(dirty\)' < <(strings "$BIN"); then
    fail "binary embeds dirty GitInfo marker"
fi

SIZE=$(stat -f%z "$BIN")
# The app binary is the launcher alone now, a few MB. The engine sits
# in MkxpCore, which is the large one.
[[ "$SIZE" -ge 2000000 ]] || fail "Empo binary suspiciously small (${SIZE} bytes)"
CORE_SIZE=$(stat -f%z "$CORE")
[[ "$CORE_SIZE" -ge 25000000 ]] || fail "MkxpCore suspiciously small (${CORE_SIZE} bytes)"

echo "OK: release artifact audit passed"
echo "    bundle: $BUNDLE_ID"
echo "    version: $VERSION ($BUILD)"
echo "    commit: $EMBEDDED_COMMIT"
echo "    binary: ${SIZE} bytes"
echo "    core: ${CORE_SIZE} bytes"
