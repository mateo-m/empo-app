#!/usr/bin/env bash
# Fail when a PSDK core framework stops being a closed boundary.
#
# The export list is the whole isolation mechanism, so it is the thing to
# check. Only psdk_ names out, no Ruby and no LiteRGSS name in.
#
# Usage:
#   cores/psdk/check-framework.sh [--sdk iphoneos|iphonesimulator]
#   cores/psdk/check-framework.sh --framework <path> --sdk <sdk>
#
# Without --framework, it checks the four PSDK cores in the build tree.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="${PLATFORM_NAME:-iphoneos}"
FRAMEWORKS=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --framework)
            FRAMEWORKS+=("$2")
            shift 2
            ;;
        --sdk)
            SDK="$2"
            shift 2
            ;;
        *)
            echo "check-framework: unknown argument $1" >&2
            exit 2
            ;;
    esac
done

if [ "${#FRAMEWORKS[@]}" -eq 0 ]; then
    for ruby in 25 30 32 33; do
        FRAMEWORKS+=("$REPO_ROOT/ios/Dependencies/build-${SDK}-arm64/Psdk${ruby}Core.framework")
    done
fi

fail() {
    echo "error: $*" >&2
    exit 1
}

# A launcher opens the core and calls every name GameCore.h declares.
# A missing one aborts in the forwarder, so fail here first.
WANT_NAMES=$("$REPO_ROOT/cores/gamecore-exports.sh" /dev/stdout)

if [ "$SDK" = iphonesimulator ]; then WANT_PLATFORM=7; else WANT_PLATFORM=2; fi

for FW in "${FRAMEWORKS[@]}"; do
    NAME="$(basename "$FW" .framework)"
    BIN="$FW/$NAME"
    [ -f "$BIN" ] ||
        fail "missing $BIN (run: cores/psdk/build-framework-ios.sh --sdk $SDK)"

    EXPORTS=$(dyld_info -exports "$BIN" | awk '/^ *0x/ {print $2}' | sort -u)

    STRAY=$(grep -vE '^_gamecore_' <<<"$EXPORTS" || true)
    [ -z "$STRAY" ] ||
        fail "$NAME exports names that are not gamecore_*: $(tr '\n' ' ' <<<"$STRAY")"

    MISSING=$(comm -23 <(echo "$WANT_NAMES") <(echo "$EXPORTS"))
    [ -z "$MISSING" ] || fail "$NAME does not export: $(tr '\n' ' ' <<<"$MISSING")"

    LEAK=$(dyld_info -imports "$BIN" | grep -E '_rb_|_ruby_|ViewportElement' || true)
    [ -z "$LEAK" ] || fail "$NAME imports engine internals: $LEAK"

    otool -D "$BIN" | grep -q "@rpath/$NAME.framework/$NAME" ||
        fail "$NAME install_name must be @rpath/$NAME.framework/$NAME"

    # Flat namespace would put the vtable capture back, across images.
    otool -hv "$BIN" | grep -q TWOLEVEL ||
        fail "$NAME must stay two-level namespace"

    otool -l "$BIN" | grep -Eq "platform ${WANT_PLATFORM}([[:space:]]|$)" ||
        fail "$NAME is not built for $SDK (platform $WANT_PLATFORM)"

    FILES="Info.plist PsdkSupport/compat.rb
        PsdkSupport/ruby-dist/lib/LiteRGSS.rb PsdkSupport/ruby-dist/lib/SFMLAudio.rb PsdkSupport/uri.rb"
    [ "$NAME" = Psdk25Core ] && FILES="$FILES PsdkSupport/litergss1.rb PsdkSupport/RubyFmod.rb"
    for f in $FILES; do
        [ -e "$FW/$f" ] || fail "$NAME.framework/$f missing"
    done

    echo "OK: $NAME.framework is closed for $SDK"
done
