#!/usr/bin/env bash
# Verify a Release iphoneos Empo.app or unsigned .ipa before publishing.
#
# Usage:
#   scripts/audit-ipa.sh path/to/Empo.app
#   scripts/audit-ipa.sh [--version X.Y.Z] path/to/Empo-unsigned.ipa
#
# --cores names the game cores the bundle must carry, and nothing else.
# Without it the script audits the cores it finds.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_VERSION=""
# Empty means "audit whatever cores the bundle has". A release passes the
# EMPO_CORES value it built with, so a core that dropped out fails here.
EXPECTED_CORES=""
KNOWN_CORES="MkxpCore PsdkCore"
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
        --cores)
            [[ $# -ge 2 ]] || fail "--cores requires a value"
            EXPECTED_CORES="$2"
            shift 2
            ;;
        -h | --help)
            echo "usage: $0 [--version X.Y.Z] [--cores \"MkxpCore PsdkCore\"] <Empo.app | Empo-unsigned.ipa>"
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
#
# A build ships one core or both (EMPO_CORES in ios/Empo/project.yml), so
# audit the cores the bundle has.
PRESENT_CORES=""
for core in $KNOWN_CORES; do
    if [[ -f "$APP/Frameworks/$core.framework/$core" ]]; then
        PRESENT_CORES="${PRESENT_CORES:+$PRESENT_CORES }$core"
    fi
done
[[ -n "$PRESENT_CORES" ]] ||
    fail "no game core in the app bundle (expected one or both of: $KNOWN_CORES)"

contains_word() {
    case " $1 " in
        *" $2 "*) return 0 ;;
    esac
    return 1
}

if [[ -n "$EXPECTED_CORES" ]]; then
    for core in $EXPECTED_CORES; do
        contains_word "$KNOWN_CORES" "$core" || fail "--cores names an unknown core: $core"
        contains_word "$PRESENT_CORES" "$core" ||
            fail "$core.framework missing from the app bundle"
    done
    for core in $PRESENT_CORES; do
        contains_word "$EXPECTED_CORES" "$core" ||
            fail "$core.framework is in the bundle, but --cores does not name it"
    done
fi

audit_core() {
    local core="$1" prefix="$2"
    local bin="$APP/Frameworks/$core.framework/$core"
    has_platform "$bin" 2 || fail "$core is not device (platform 2)"
    ! has_platform "$bin" 7 || fail "$core contains simulator objects"

    # The whole point of the framework: no Ruby and no SDL name escapes
    # it, so a second core cannot bind to this one's definitions.
    local stray
    stray=$(nm -gU "$bin" | awk -v p="^$prefix" '$3 !~ p {print $3}')
    [[ -z "$stray" ]] ||
        fail "$core exports a name that is not ${prefix}*: $(tr '\n' ' ' <<<"$stray")"

    codesign --verify --strict "$bin" 2>/dev/null ||
        fail "$core.framework is not signed (the app's own signature does not reach inside it)"
}

for core in $PRESENT_CORES; do
    case "$core" in
        MkxpCore) audit_core MkxpCore _mkxp_ ;;
        PsdkCore) audit_core PsdkCore _psdk_ ;;
    esac
done

if contains_word "$PRESENT_CORES" MkxpCore; then
    MKXP="$APP/Frameworks/MkxpCore.framework/MkxpCore"
    for ver in 18 19 31; do
        sym="_mkxp_get_script_binding_${ver}"
        nm "$MKXP" 2>/dev/null | awk -v sym="$sym" '$3 == sym {found=1} END {exit !found}' ||
            fail "MkxpCore missing ${sym}"
    done
fi

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Info.plist")

[[ "$BUNDLE_ID" == "sh.mateo.empo" ]] ||
    fail "unexpected bundle id: $BUNDLE_ID (expected sh.mateo.empo for release IPA)"

if [[ -n "$EXPECTED_VERSION" && "$VERSION" != "$EXPECTED_VERSION" ]]; then
    fail "Info.plist version $VERSION != expected $EXPECTED_VERSION"
fi

HEAD_COMMIT=$(git -C "$REPO_ROOT" rev-parse --short HEAD)

# The Release optimiser folds the whole line into one string, so the
# dirty marker arrives on the commit line and not on a line of its own.
# Read the line first, then test it. A grep that finds nothing inside a
# command substitution fails the assignment, and set -e would end the
# script with no word about why.
GIT_LINE=$(grep -m1 -E '^commit: ' < <(strings "$BIN") || true)
[[ -n "$GIT_LINE" ]] || fail "embedded GitInfo commit not found in binary"
[[ "$GIT_LINE" != *"(dirty)"* ]] ||
    fail "binary embeds a dirty GitInfo marker ($GIT_LINE)"

EMBEDDED_COMMIT=$(awk '{print $2}' <<<"$GIT_LINE")
[[ "$EMBEDDED_COMMIT" == "$HEAD_COMMIT" ]] ||
    fail "embedded commit $EMBEDDED_COMMIT != HEAD $HEAD_COMMIT"

SIZE=$(stat -f%z "$BIN")
# The app binary is the launcher alone now, a few MB. The engines sit in
# the cores, which are the large ones.
[[ "$SIZE" -ge 2000000 ]] || fail "Empo binary suspiciously small (${SIZE} bytes)"

CORE_SIZES=""
for core in $PRESENT_CORES; do
    core_size=$(stat -f%z "$APP/Frameworks/$core.framework/$core")
    case "$core" in
        MkxpCore) min=25000000 ;;
        PsdkCore) min=15000000 ;;
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
