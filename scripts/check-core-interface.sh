#!/usr/bin/env bash
# Fail when a core stops matching the launcher interface Empo calls.
#
# Empo links no engine. It opens one core with dlopen and resolves every
# name in it, each core under its own prefix:
#
#   Empo      ios/Empo/src/App/GameCore.h          gamecore_ / GameCore
#   MkxpCore  mkxp-z-apple-mobile/src/app_bridge.h mkxp_     / MKXP
#   PsdkCore  ios/Dependencies/psdk/psdk_app_bridge.h  psdk_ / Psdk
#
# GameCore.h holds only what Empo calls. A core header can hold more,
# for example the half of app_bridge.h that the mkxp engine calls. So
# every statement in GameCore.h must be in each core header, with the
# same arguments and the same constants. The check replaces each prefix
# with one neutral word, drops the comments and the preprocessor lines,
# and compares statement by statement.
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
        grep -vE '^(extern "C" \{|\})$' |
        sed -E -e 's/(MKXP|Psdk|GameCore)(VerticalAlignment|SyntaxTransformMode|RubyVersion|PointerPhase|SessionConfig)/CoreType\2/g' \
            -e 's/(mkxp|psdk|gamecore)_/core_/g' \
            -e 's/(MKXP|PSDK|GAMECORE)_/CORE_/g' |
        tr -s '[:space:]' ' ' |
        perl -ne 'my $d = 0; my $t = ""; for my $c (split //) { $d++ if $c eq "{"; $d-- if $c eq "}"; $t .= $c; if ($c eq ";" && $d == 0) { $t =~ s/^ +| +$//g; print "$t\n"; $t = ""; } }' |
        sort
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

COUNT=$(grep -c 'core_[A-Za-z]' "$TMP/empo" || true)
if [ "$COUNT" -lt 50 ]; then
    echo "check-core-interface: only $COUNT names read from GameCore.h, refusing" >&2
    exit 1
fi

STATUS=0
for side in mkxp psdk; do
    MISSING="$(comm -23 "$TMP/empo" "$TMP/$side")"
    if [ -n "$MISSING" ]; then
        echo "check-core-interface: $side does not answer these statements of GameCore.h:"
        echo "$MISSING"
        STATUS=1
    fi
done

if [ "$STATUS" -eq 0 ]; then
    echo "check-core-interface: both cores answer GameCore.h ($COUNT statements)"
fi
exit "$STATUS"
