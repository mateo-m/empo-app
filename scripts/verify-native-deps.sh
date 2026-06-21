#!/usr/bin/env bash
# Verify native dependency artifacts for one SDK tree (iphoneos or
# iphonesimulator). Used by Xcode pre-build, fetch-native-deps.sh, and CI.
#
# Usage:
#   PLATFORM_NAME=iphoneos scripts/verify-native-deps.sh
#   PLATFORM_NAME=iphonesimulator scripts/verify-native-deps.sh
#
# Exits 0 when mkxp merged objects and core Ruby/OpenSSL archives look
# healthy for the requested platform.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM="${PLATFORM_NAME:-iphoneos}"
LIB="$REPO_ROOT/ios/Dependencies/build-${PLATFORM}-arm64/lib"

fail() {
    echo "error: $*" >&2
    exit 1
}

require_file_min() {
    local path="$1" min_bytes="$2" label="$3"
    [[ -f "$path" ]] || fail "missing $label ($path)"
    local size
    size=$(stat -f%z "$path")
    [[ "$size" -ge "$min_bytes" ]] || fail "$label too small (${size} bytes; need >= ${min_bytes})"
}

has_platform() {
    local path="$1" platform="$2"
    otool -l "$path" 2>/dev/null | grep -Em1 "platform ${platform}" >/dev/null
}

require_platform() {
    local path="$1" expected="$2" label="$3"
    if ! has_platform "$path" "$expected"; then
        fail "$label missing platform $expected objects"
    fi
    if [ "$expected" = "2" ] && has_platform "$path" 7; then
        fail "$label contains simulator (platform 7) objects"
    fi
    if [ "$expected" = "7" ] && has_platform "$path" 2; then
        fail "$label contains device (platform 2) objects"
    fi
}

if [ "$PLATFORM" = "iphonesimulator" ]; then
    EXPECTED_PLATFORM=7
else
    EXPECTED_PLATFORM=2
fi

echo "==> verifying native deps for $PLATFORM"

for ver in 18 19 31; do
    merged="$LIB/mkxp${ver}-merged.o"
    require_file_min "$merged" 1000000 "mkxp${ver}-merged.o"
    require_platform "$merged" "$EXPECTED_PLATFORM" "mkxp${ver}-merged.o"
    sym="_mkxp_get_script_binding_${ver}"
    nm "$merged" 2>/dev/null | awk -v sym="$sym" '$3 == sym {found=1} END {exit !found}' ||
        fail "mkxp${ver}-merged.o missing ${sym}"
done

for name in libruby.3.1-static.a libruby.3.1-ext.a libruby18-static.a libruby18-ext.a \
    libruby19-static.a libruby19-ext.a libcrypto.a libssl.a libSDL2.a libSDL2_ttf.a; do
    path="$LIB/$name"
    min=100000
    case "$name" in
        libruby.3.1-static.a | libruby18-static.a | libruby19-static.a) min=1000000 ;;
        libruby.3.1-ext.a) min=5000000 ;;
        libcrypto.a) min=1000000 ;;
        libSDL2.a) min=500000 ;;
        libSDL2_ttf.a) min=40000 ;;
    esac
    require_file_min "$path" "$min" "$name"
    require_platform "$path" "$EXPECTED_PLATFORM" "$name"
done

echo "OK: $PLATFORM native dependency artifacts look healthy"
