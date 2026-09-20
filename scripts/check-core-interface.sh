#!/usr/bin/env bash
# Fail when the three copies of the launcher interface drift apart.
#
# Empo links no engine. It opens one core with dlopen and resolves every
# name in it. So the same interface exists three times, once per side,
# each under its own prefix:
#
#   Empo      ios/Empo/src/App/GameCore.h          gamecore_ / GameCore
#   MkxpCore  mkxp-z-apple-mobile/src/app_bridge.h mkxp_     / MKXP
#   PsdkCore  ios/Dependencies/psdk/psdk_app_bridge.h  psdk_ / Psdk
#
# A core that drops a name, changes an argument, or renumbers a constant
# makes Empo abort in the forwarder at run time. This check reads the
# three files, replaces each prefix with one neutral word, drops the
# comments and the preprocessor lines, and compares what is left.
#
# app_bridge.h holds a second half for the desktop build of mkxp-z, with
# inline no-op stubs behind #else. The read stops at that line.
#
# Usage:
#   scripts/check-core-interface.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EMPO="$ROOT/ios/Empo/src/App/GameCore.h"
MKXP="$ROOT/mkxp-z-apple-mobile/src/app_bridge.h"
PSDK="$ROOT/ios/Dependencies/psdk/psdk_app_bridge.h"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

normalize() {
    awk '/^#else \/\* !MKXPZ_MOBILE \*\//{exit} {print}' "$1" |
        perl -0777 -pe 's{/\*.*?\*/}{ }gs' |
        sed -e 's://.*::' |
        grep -v '^[[:space:]]*#' |
        sed -E -e 's/(MKXP|Psdk|GameCore)(VerticalAlignment|SyntaxTransformMode|RubyVersion|PointerPhase|SessionConfig)/CoreType\2/g' \
            -e 's/(mkxp|psdk|gamecore)_/core_/g' \
            -e 's/(MKXP|PSDK|GAMECORE)_/CORE_/g' |
        tr -s '[:space:]' '\n' |
        grep -v '^$'
}

for f in "$EMPO" "$MKXP" "$PSDK"; do
    [ -f "$f" ] || {
        echo "check-core-interface: $f missing" >&2
        exit 1
    }
done

normalize "$EMPO" >"$TMP/empo"
normalize "$MKXP" >"$TMP/mkxp"
normalize "$PSDK" >"$TMP/psdk"

COUNT=$(grep -c '^core_[A-Za-z]' "$TMP/empo" || true)
if [ "$COUNT" -lt 80 ]; then
    echo "check-core-interface: only $COUNT names read from GameCore.h, refusing" >&2
    exit 1
fi

STATUS=0
for side in mkxp psdk; do
    if ! diff -u "$TMP/empo" "$TMP/$side" >"$TMP/$side.diff"; then
        echo "check-core-interface: $side drifted from Empo's GameCore.h"
        sed -n '1,60p' "$TMP/$side.diff"
        STATUS=1
    fi
done

if [ "$STATUS" -eq 0 ]; then
    echo "check-core-interface: the three copies match ($COUNT names)"
fi
exit "$STATUS"
