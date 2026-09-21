#!/usr/bin/env bash
# Fail when MkxpCore.framework stops being a closed boundary.
#
# The export list is the whole isolation mechanism, so it is the thing
# to check. The mkxp_ bridge out, no Ruby and no SDL name in or out.
#
# Usage:
#   scripts/check-mkxp-framework.sh [--sdk iphoneos|iphonesimulator]
#   scripts/check-mkxp-framework.sh --framework <path> --sdk <sdk>
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
            echo "check-mkxp-framework: unknown argument $1" >&2
            exit 2
            ;;
    esac
done

[ -n "$FW" ] || FW="$REPO_ROOT/ios/Dependencies/build-${SDK}-arm64/MkxpCore.framework"

fail() {
    echo "error: $*" >&2
    exit 1
}

BIN="$FW/MkxpCore"
[ -f "$BIN" ] ||
    fail "missing $BIN (run: tools/mkxp-core/build-framework-ios.sh --sdk $SDK)"

# The header is the contract. Anything it declares must be out, and
# nothing else may be.
WANT=$(grep -oE '\bmkxp_[A-Za-z0-9_]+\(' "$REPO_ROOT/mkxp-z-apple-mobile/src/app_bridge.h" |
    sed 's/(//' | sort -u | sed 's/^/_/')
GOT=$(dyld_info -exports "$BIN" | awk '/^ *0x/ {print $2}' | sort -u)
if [ "$WANT" != "$GOT" ]; then
    echo "error: MkxpCore exports do not match app_bridge.h" >&2
    diff <(echo "$WANT") <(echo "$GOT") >&2 || true
    exit 1
fi

LEAK=$(dyld_info -imports "$BIN" | grep -E '_rb_|_ruby_|_SDL_' || true)
[ -z "$LEAK" ] || fail "MkxpCore imports engine internals: $LEAK"

otool -D "$BIN" | grep -q '@rpath/MkxpCore.framework/MkxpCore' ||
    fail "MkxpCore install_name must be @rpath/MkxpCore.framework/MkxpCore"

# Flat namespace would let a second core bind to these names.
otool -hv "$BIN" | grep -q TWOLEVEL ||
    fail "MkxpCore must stay two-level namespace"

if [ "$SDK" = iphonesimulator ]; then WANT_PLATFORM=7; else WANT_PLATFORM=2; fi
otool -l "$BIN" | grep -Eq "platform ${WANT_PLATFORM}([[:space:]]|$)" ||
    fail "MkxpCore is not built for $SDK (platform $WANT_PLATFORM)"

for f in Assets.bundle/Shaders/common.h Assets.bundle/Fonts/liberation.ttf \
    Assets.bundle/gamecontrollerdb.txt Assets.bundle/Preload Assets.bundle/Postload \
    Ruby/3.1.0 Headers/app_bridge.h Info.plist; do
    [ -e "$FW/$f" ] || fail "MkxpCore.framework/$f missing"
done

# GameImportValidator reads this at import, before any core is open. A
# missing key makes every RPG Maker import fail as unsupported, and a
# key that says 3 on a core that runs RGSS3 refuses every VX Ace game.
#
# So check it against the image: mask 7 means the patched Ruby 3.1 is
# linked, and the patched Ruby defines
# mkxp_syntax_transform_target_ruby_version_major. The same #ifdef
# drives mkxp_getSupportedRGSSVersionMask, so the two answers are one
# fact. nm -a, because the merged objects hide every Ruby name.
#
# grep -c and not grep -q: grep -q leaves on the first match, nm dies on
# SIGPIPE, and pipefail reads that as no match.
MASK="$(/usr/libexec/PlistBuddy -c 'Print :EmpoCoreRGSSVersionMask' "$FW/Info.plist" 2>/dev/null || true)"
PATCHED_RUBY_COUNT="$(nm -a "$BIN" | grep -c '_mkxp_syntax_transform_target_ruby_version_major$' || true)"
if [ "$PATCHED_RUBY_COUNT" -gt 0 ]; then
    WANT_MASK=7
else
    WANT_MASK=3
fi
[ "$MASK" = "$WANT_MASK" ] ||
    fail "Info.plist EmpoCoreRGSSVersionMask is ${MASK:-missing}, but the image says $WANT_MASK"

# The tree keeps the framework between builds, so a change to the build
# script leaves a framework nothing rebuilt. Match the recorded hash
# against the script on disk.
SCRIPT="$REPO_ROOT/tools/mkxp-core/build-framework-ios.sh"
WANT_SCRIPT="$(shasum -a 256 "$SCRIPT" | awk '{print $1}')"
GOT_SCRIPT="$(cat "$FW/.build-script-sha256" 2>/dev/null || true)"
[ "$WANT_SCRIPT" = "$GOT_SCRIPT" ] ||
    fail "MkxpCore.framework was built by a different build-framework-ios.sh (run: scripts/rebuild-engine-halves.sh $SDK)"

echo "OK: MkxpCore.framework is closed for $SDK"
