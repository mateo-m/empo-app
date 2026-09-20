#!/bin/sh
# Install PsdkTests.app on a booted simulator, put a game in its data
# container, and run it.
#
# The game folder stays out of the app bundle. A released PSDK game is
# hundreds of megabytes, and the game writes next to its own files, so it
# goes into Documents, which is writable.
#
# Usage:
#   tools/psdk-core/run-test-host-ios.sh --game <dir> [--seconds 90]
#                                       [--snap-every 5] [--device <udid>]
#                                       [--keys 50:36,56:2] [--rotate 60:4]
#                                       [--fast-forward 4]
#
# --keys presses SFML scancodes at the given second, to drive the game
# without a person at the keyboard. host.m explains the format.
#
# The snapshots come from `simctl io screenshot`, not from the game. A
# picture of the display proves the frame was presented. A picture the
# game draws for itself only proves it rendered.
#
# Prerequisite: tools/psdk-core/build-test-host-ios.sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/build/psdk-core/PsdkTests.app"
BUNDLE_ID=sh.mateo.empo.psdktests

GAME=
SECONDS_TO_RUN=90
SNAP_EVERY=5
DEVICE=
KEYS=
ROTATE=
FAST_FORWARD=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --game)
            GAME="$2"
            shift 2
            ;;
        --seconds)
            SECONDS_TO_RUN="$2"
            shift 2
            ;;
        --snap-every)
            SNAP_EVERY="$2"
            shift 2
            ;;
        --device)
            DEVICE="$2"
            shift 2
            ;;
        --keys)
            KEYS="$2"
            shift 2
            ;;
        --rotate)
            ROTATE="$2"
            shift 2
            ;;
        --fast-forward)
            FAST_FORWARD="$2"
            shift 2
            ;;
        *)
            echo "run-test-host-ios: unknown argument $1" >&2
            exit 2
            ;;
    esac
done

[ -n "$GAME" ] || {
    echo "run-test-host-ios: --game is required" >&2
    exit 2
}
[ -f "$GAME/Game.rb" ] || {
    echo "run-test-host-ios: $GAME holds no Game.rb" >&2
    exit 1
}
[ -d "$APP" ] || {
    echo "run-test-host-ios: build the host first" >&2
    exit 1
}

if [ -z "$DEVICE" ]; then
    DEVICE=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
fi
[ -n "$DEVICE" ] || {
    echo "run-test-host-ios: no booted simulator" >&2
    exit 1
}

echo "[psdk-run] device $DEVICE"
xcrun simctl install "$DEVICE" "$APP"

DATA=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)
DOCS="$DATA/Documents"
mkdir -p "$DOCS"

# The Windows binaries in a release are dead weight on iOS, and copying
# them costs minutes. Only what Ruby and LiteRGSS read goes across.
echo "[psdk-run] copying the game into $DOCS/Game"
rm -rf "$DOCS/Game" "$DOCS/snaps"
mkdir -p "$DOCS/Game" "$DOCS/snaps"
(cd "$GAME" && tar -cf - \
    --exclude='*.dll' --exclude='*.exe' --exclude='ruby_builtin_dlls' \
    --exclude='*.so' --exclude='*.bundle' \
    .) | (cd "$DOCS/Game" && tar -xf -)

# iOS opens files case-sensitively, and a released game can ask for a
# spelling it did not ship. normalize-case.py explains the whole thing.
python3 "$(dirname "$0")/normalize-case.py" "$DOCS/Game"

SNAPS="$ROOT/build/psdk-core/snaps"
rm -rf "$SNAPS"
mkdir -p "$SNAPS"

echo "[psdk-run] launching for ${SECONDS_TO_RUN}s"
SIMCTL_CHILD_PSDK_RUN_FOR="$SECONDS_TO_RUN" \
    SIMCTL_CHILD_PSDK_KEYS="$KEYS" \
    SIMCTL_CHILD_PSDK_SCALE="${PSDK_SCALE:-}" \
    SIMCTL_CHILD_PSDK_ROTATE="$ROTATE" \
    SIMCTL_CHILD_PSDK_FAST_FORWARD="$FAST_FORWARD" \
    xcrun simctl launch --console-pty "$DEVICE" "$BUNDLE_ID" &
LAUNCH_PID=$!

# simctl gives no frame-ready event, so the shots go on a fixed beat.
# The beat is the test's sampling rate, not a wait for a signal.
ELAPSED=0
while [ "$ELAPSED" -lt "$SECONDS_TO_RUN" ]; do
    sleep "$SNAP_EVERY"
    ELAPSED=$((ELAPSED + SNAP_EVERY))
    kill -0 "$LAUNCH_PID" 2>/dev/null || break
    xcrun simctl io "$DEVICE" screenshot --type=png \
        "$SNAPS/$(printf 't%03d' "$ELAPSED").png" >/dev/null 2>&1 || true
done

wait "$LAUNCH_PID" || true

echo "[psdk-run] snapshots in $SNAPS"
ls -la "$SNAPS"
