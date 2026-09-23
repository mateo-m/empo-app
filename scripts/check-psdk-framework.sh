#!/usr/bin/env bash
# Fail when PsdkCore.framework stops being a closed boundary.
#
# The export list is the whole isolation mechanism, so it is the thing to
# check. Only psdk_ names out, no Ruby and no LiteRGSS name in.
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

EXPORTS=$(dyld_info -exports "$BIN" | awk '/^ *0x/ {print $2}' | sort -u)

# psdk_run and psdk_inject_scancode are what psdk_core.h declares, and
# the test host calls them straight. Everything else is the launcher
# interface from psdk_app_bridge.cpp.
for want in _psdk_run _psdk_inject_scancode; do
    grep -qx "$want" <<<"$EXPORTS" || fail "PsdkCore does not export $want"
done

STRAY=$(grep -vE '^_psdk_' <<<"$EXPORTS" || true)
[ -z "$STRAY" ] ||
    fail "PsdkCore exports names that are not psdk_*: $(tr '\n' ' ' <<<"$STRAY")"

# A launcher opens the core and calls every name the header declares. A
# missing one aborts in the forwarder, so fail here first.
WANT_NAMES=$(grep -oE '\bpsdk_[A-Za-z0-9_]+\(' "$REPO_ROOT/ios/Dependencies/psdk/psdk_app_bridge.h" |
    sed 's/(//' | sort -u | sed 's/^/_/')
MISSING=$(comm -23 <(echo "$WANT_NAMES") <(echo "$EXPORTS"))
[ -z "$MISSING" ] || fail "PsdkCore does not export: $(tr '\n' ' ' <<<"$MISSING")"

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
    PsdkSupport/uri.rb Headers/psdk_core.h runtime_prelude.rb Info.plist; do
    [ -e "$FW/$f" ] || fail "PsdkCore.framework/$f missing"
done

# The tree keeps the framework between builds, so a change to the build
# script leaves a framework nothing rebuilt. Match the recorded hash
# against the script on disk.
SCRIPT="$REPO_ROOT/tools/psdk-core/build-framework-ios.sh"
WANT_SCRIPT="$(shasum -a 256 "$SCRIPT" | awk '{print $1}')"
GOT_SCRIPT="$(cat "$FW/.build-script-sha256" 2>/dev/null || true)"
[ "$WANT_SCRIPT" = "$GOT_SCRIPT" ] ||
    fail "PsdkCore.framework was built by a different build-framework-ios.sh (run: tools/psdk-core/build-framework-ios.sh --sdk $SDK)"

echo "OK: PsdkCore.framework is closed for $SDK"
