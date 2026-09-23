#!/bin/sh
# Install MkxpTests.app on a booted simulator, put a game in its data
# container, and run it.
#
# The game folder stays out of the app bundle. The game writes next to
# its own files, so it goes into Documents, which is writable.
#
# Usage:
#   tools/mkxp-core/run-test-host-ios.sh --game <dir> [--seconds 90]
#                                        [--snap-every 5] [--device <udid>]
#                                        [--keys 20:29,26:40] [--load-at 2]
#                                        [--also-open PsdkCore.framework]
#
# --keys presses MKXP_SCANCODE_* values at the given second, to drive
# the game without a person at the keyboard. host.m explains the format.
#
# The snapshots come from `simctl io screenshot`, not from the game. A
# picture of the display proves the frame was presented.
#
# Prerequisite: tools/mkxp-core/build-test-host-ios.sh
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/build/mkxp-core/MkxpTests.app"
BUNDLE_ID=sh.mateo.empo.mkxptests

GAME=
SECONDS_TO_RUN=90
SNAP_EVERY=5
DEVICE=
KEYS=
LOAD_AT=2
ALSO_OPEN=

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
        --load-at)
            LOAD_AT="$2"
            shift 2
            ;;
        --also-open)
            ALSO_OPEN="$2"
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
[ -f "$GAME/Game.ini" ] || [ -f "$GAME/mkxp.json" ] || {
    echo "run-test-host-ios: $GAME holds no Game.ini and no mkxp.json" >&2
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

echo "[mkxp-run] device $DEVICE"
xcrun simctl install "$DEVICE" "$APP"

DATA=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" data)
DOCS="$DATA/Documents"
mkdir -p "$DOCS"

echo "[mkxp-run] copying the game into $DOCS/Game"
rm -rf "$DOCS/Game"
mkdir -p "$DOCS/Game"
(cd "$GAME" && tar -cf - \
    --exclude='*.dll' --exclude='*.exe' --exclude='ruby_builtin_dlls' \
    --exclude='*.so' \
    .) | (cd "$DOCS/Game" && tar -xf -)

SNAPS="$ROOT/build/mkxp-core/snaps"
rm -rf "$SNAPS"
mkdir -p "$SNAPS"

echo "[mkxp-run] launching for ${SECONDS_TO_RUN}s"
SIMCTL_CHILD_MKXP_RUN_FOR="$SECONDS_TO_RUN" \
    SIMCTL_CHILD_MKXP_KEYS="$KEYS" \
    SIMCTL_CHILD_MKXP_LOAD_AT="$LOAD_AT" \
    SIMCTL_CHILD_MKXP_ALSO_OPEN="$ALSO_OPEN" \
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

echo "[mkxp-run] snapshots in $SNAPS"
ls -la "$SNAPS"
