#!/bin/sh
# Prove that a key press reaches a released PSDK game.
#
# LiteRGSS hands the key-pressed event to a Ruby proc. Upstream commit
# f582db8 put the scancode in front of the flags, and a game built before
# that commit registers a proc of two parameters, so the scancode lands
# where "alt is down" belongs. A scancode is never nil, so every key read
# as Alt, and PSDK answers Alt+Enter with Graphics.swap_fullscreen. The
# confirm key changed the video mode and set no key at all.
#
# DisplayWindowInput.cpp reads the proc's arity and sends the shape that
# proc asks for. This check drives the real game and reads what PSDK
# holds down, which is the answer the game itself reads.
#
# Usage: check-key-arity-ios.sh --game <dir> [--device <udid>]
# Prerequisite: tools/psdk-core/build-test-host-ios.sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
GAME=
DEVICE=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --game)
            GAME="$2"
            shift 2
            ;;
        --device)
            DEVICE="$2"
            shift 2
            ;;
        *)
            echo "unknown option: $1" >&2
            exit 2
            ;;
    esac
done

[ -n "$GAME" ] || {
    echo "usage: check-key-arity-ios.sh --game <dir>" >&2
    exit 2
}

# A PSDK game writes its key map to input.json in its home folder and
# reads it back at the next boot. A map from an older core build holds
# numbers this core never sends, and the game then answers no key at
# all. The check needs the game's own defaults, so the saved map goes.
SIM="${DEVICE:-booted}"
DATA=$(xcrun simctl get_app_container "$SIM" sh.mateo.empo.psdktests data 2>/dev/null || true)
if [ -n "$DATA" ]; then
    find "$DATA" -name input.json -delete 2>/dev/null || true
fi

# 36 is the SFML scancode of Enter. PSDK binds it to its A key, which is
# confirm. Two presses, because the first one can land while the game is
# still loading its scripts.
set -- --game "$GAME" --seconds 60 --snap-every 30 --keys 30:36,45:36
[ -n "$DEVICE" ] && set -- "$@" --device "$DEVICE"

LOG=$(mktemp -t psdk-key-arity)
"$HERE/run-test-host-ios.sh" "$@" >"$LOG" 2>&1 || true

echo "--- what the game reported"
grep -E 'PSDK-MAP|PSDK-KEY' "$LOG" || true

if grep -q 'PSDK-KEY .* down=\[:A\]' "$LOG"; then
    echo "OK: Enter reaches the game as its A key"
    rm -f "$LOG"
    exit 0
fi

echo "FAIL: no press set PSDK's A key. Full log: $LOG" >&2
exit 1
