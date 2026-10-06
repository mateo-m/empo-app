#!/bin/sh
# Writes the linker export list of a core: every function GameCore.h
# declares, and nothing else. The linker fails when the bridge does not
# define one of them.
#
# Usage:
#   cores/gamecore-exports.sh <out-file>
set -eu

HEADER="$(cd "$(dirname "$0")" && pwd)/GameCore.h"
[ "$#" -eq 1 ] || {
    echo "usage: gamecore-exports.sh <out-file>" >&2
    exit 2
}

NAMES=$(grep -oE '\bgamecore_[A-Za-z0-9_]+\(' "$HEADER" | sed -e 's/(//' -e 's/^/_/' | sort -u)
COUNT=$(printf '%s\n' "$NAMES" | wc -l)
[ "$COUNT" -ge 40 ] || {
    echo "gamecore-exports: only $COUNT names read from $HEADER, refusing" >&2
    exit 1
}
printf '%s\n' "$NAMES" >"$1"
