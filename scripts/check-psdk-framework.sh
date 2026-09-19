#!/usr/bin/env bash
# Fail when PsdkCore.framework stops being a closed boundary.
#
# The export list is the whole isolation mechanism, so it is the thing to
# check. Two names out, no Ruby and no LiteRGSS name in.
#
# Usage:
#   scripts/check-psdk-framework.sh [--sdk iphoneos|iphonesimulator]
#   scripts/check-psdk-framework.sh --framework <path> --sdk <sdk>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${PLATFORM_NAME:-iphoneos}"
FW=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --framework)
            FW="$2"
            shift 2
            ;;
        --sdk)
            SDK="$2"
            shift 2
            ;;
        *)
            echo "check-psdk-framework: unknown argument $1" >&2
            exit 2
            ;;
    esac
done

[ -n "$FW" ] || FW="$REPO_ROOT/ios/Dependencies/build-${SDK}-arm64/PsdkCore.framework"

fail() {
    echo "error: $*" >&2
    exit 1
}

BIN="$FW/PsdkCore"
[ -f "$BIN" ] ||
    fail "missing $BIN (run: tools/psdk-core/build-framework-ios.sh --sdk $SDK)"

EXPORTS=$(dyld_info -exports "$BIN" | awk '/^ *0x/ {print $2}' | sort -u | tr '\n' ' ')
[ "$EXPORTS" = "_psdk_inject_scancode _psdk_run " ] ||
    fail "PsdkCore must export exactly _psdk_run and _psdk_inject_scancode (got: $EXPORTS)"

LEAK=$(dyld_info -imports "$BIN" | grep -E '_rb_|_ruby_|ViewportElement' || true)
[ -z "$LEAK" ] || fail "PsdkCore imports engine internals: $LEAK"

otool -D "$BIN" | grep -q '@rpath/PsdkCore.framework/PsdkCore' ||
    fail "PsdkCore install_name must be @rpath/PsdkCore.framework/PsdkCore"

# Flat namespace would put the vtable capture back, across images.
otool -hv "$BIN" | grep -q TWOLEVEL ||
    fail "PsdkCore must stay two-level namespace"

if [ "$SDK" = iphonesimulator ]; then WANT=7; else WANT=2; fi
otool -l "$BIN" | grep -Eq "platform ${WANT}([[:space:]]|$)" ||
    fail "PsdkCore is not built for $SDK (platform $WANT)"

for f in PsdkSupport/ruby-dist/lib/LiteRGSS.rb PsdkSupport/ruby-dist/lib/SFMLAudio.rb \
    PsdkSupport/uri.rb Headers/psdk_core.h Info.plist; do
    [ -e "$FW/$f" ] || fail "PsdkCore.framework/$f missing"
done

echo "OK: PsdkCore.framework is closed for $SDK"
