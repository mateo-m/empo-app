#!/usr/bin/env bash
# Verify native dependency artifacts for one SDK tree (iphoneos or
# iphonesimulator). Xcode pre-build, fetch-native-deps.sh, and CI use it.
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
    local out
    # Slurp the otool output. Under set -o pipefail, an early-exit grep
    # pipeline SIGPIPEs otool and makes has_platform falsely fail.
    out=$(otool -l "$path" 2>/dev/null) || return 1
    grep -Eq "platform ${platform}([[:space:]]|$)" <<<"$out"
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

# Networking: every VM must carry the statically-linked socket ext.
# The merge hides Init_socket as a local symbol inside the merged
# object, so look in the ext archives, which are the merge inputs.
# The pure-Ruby stdlib trees the launcher bundles must also exist.
# Use awk (not `grep -q`) to drain nm's output: with pipefail,
# grep -q's early exit SIGPIPEs nm and fails the pipeline on a
# *successful* match.
for ext in libruby18-ext.a libruby19-ext.a "libruby.3.1-ext.a"; do
    nm "$LIB/$ext" 2>/dev/null | awk '$2 == "T" && $3 == "_Init_socket" {found=1} END {exit !found}' ||
        fail "$ext missing Init_socket (socket ext dropped out of the build)"
done
nm "$LIB/libruby.3.1-ext.a" 2>/dev/null | awk '$2 == "T" && $3 == "_Init_openssl" {found=1} END {exit !found}' ||
    fail "libruby.3.1-ext.a missing Init_openssl"
for tree in 3.1.0/net/http.rb 3.1.0/openssl.rb 1.9.1/uri.rb 1.8/uri.rb; do
    [ -f "$REPO_ROOT/ios/Dependencies/build-${PLATFORM}-arm64/ruby-stdlib/$tree" ] ||
        fail "ruby-stdlib/$tree missing (run: make -f ${PLATFORM}.make ruby-stdlib)"
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

# Staleness guard: binding/*.cpp + hmode7 + engine headers compile into
# the prebuilt mkxp*-merged.o files, NOT into the Xcode build (see the
# note above OTHER_LDFLAGS in ios/Empo/project.yml). If you edit those
# sources and do not re-run `make mkxp-merged`, the link silently uses
# stale engine code. common.make stamps a content hash of that source
# set next to the merged objects. Recompute and compare it here so the
# Xcode build fails loudly instead. The check is content-based (not
# mtime), so prebuilt tarballs still verify on fresh clones.
FINGERPRINT_FILE="$LIB/.mkxp-binding-fingerprint"
FINGERPRINT_SCRIPT="$REPO_ROOT/mkxp-z-apple-mobile/tools/binding-fingerprint.sh"
if [[ -f "$FINGERPRINT_FILE" ]]; then
    recorded="$(cat "$FINGERPRINT_FILE")"
    current="$("$FINGERPRINT_SCRIPT")"
    if [[ "$current" != "$recorded" ]]; then
        fail "mkxp merged objects are STALE for $PLATFORM: binding/hmode7/engine-header \
sources changed since mkxp*-merged.o was built. Rebuild with: \
cd ios/Dependencies && make -f ${PLATFORM}.make mkxp-merged"
    fi
elif [[ "${EMPO_ALLOW_UNSTAMPED:-0}" == "1" ]]; then
    echo "warning: $FINGERPRINT_FILE missing, staleness check skipped (EMPO_ALLOW_UNSTAMPED=1)" >&2
else
    # Every supported tree carries the stamp as of native-2026-07-16
    # (make mkxp-merged writes it, and the published tarball includes
    # it). A missing stamp means an ancient tree whose merged objects
    # you cannot trust. The stale-msgbox bug shipped exactly this way,
    # so fail instead of warn. EMPO_ALLOW_UNSTAMPED=1 overrides this
    # for archaeology on pre-stamp trees.
    fail "$FINGERPRINT_FILE missing: cannot prove mkxp*-merged.o match the binding \
sources. Rebuild with: cd ios/Dependencies && make -f ${PLATFORM}.make mkxp-merged \
(or re-hydrate: rm -rf ios/Dependencies/build-* ios/Dependencies/native/.fetched-version, \
then build). Set EMPO_ALLOW_UNSTAMPED=1 to bypass."
fi

# Engine core: everything under mkxp-z-apple-mobile/src compiles into
# the prebuilt libmkxpz-core.a. The engine repo's
# tools/build-core-ios.sh builds it, via `make mkxp-core` or as a
# fetched published artifact. Same staleness contract as the merged
# objects above: the build stamps a content hash of the engine src
# tree. Recompute and compare it here, so an engine-source edit
# without a core rebuild fails loudly instead of linking stale code.
# Only tools/fetch-native-deps.sh sets SKIP_ENGINE_CORE_CHECK=1, and
# its hydration finishes before the engine-core channel has run.
if [[ "${SKIP_ENGINE_CORE_CHECK:-0}" == "1" ]]; then
    echo "note: engine-core check skipped (native hydration in progress)"
    echo "OK: $PLATFORM native dependency artifacts look healthy"
    exit 0
fi

CORE_LIB="$LIB/libmkxpz-core.a"
require_file_min "$CORE_LIB" 1000000 "libmkxpz-core.a"
require_platform "$CORE_LIB" "$EXPECTED_PLATFORM" "libmkxpz-core.a"

CORE_FP_FILE="$LIB/.mkxp-core-fingerprint"
CORE_FP_SCRIPT="$REPO_ROOT/mkxp-z-apple-mobile/tools/core-fingerprint.sh"
if [[ -f "$CORE_FP_FILE" ]]; then
    recorded="$(cat "$CORE_FP_FILE")"
    current="$("$CORE_FP_SCRIPT")"
    if [[ "$current" != "$recorded" ]]; then
        fail "libmkxpz-core.a is STALE for $PLATFORM: engine sources changed since it \
was built (or the fetched engine prebuilt does not match the checked-out submodule). \
Rebuild with: cd ios/Dependencies && make -f ${PLATFORM}.make mkxp-core"
    fi
elif [[ "${EMPO_ALLOW_UNSTAMPED:-0}" == "1" ]]; then
    echo "warning: $CORE_FP_FILE missing, core staleness check skipped (EMPO_ALLOW_UNSTAMPED=1)" >&2
else
    fail "$CORE_FP_FILE missing: cannot prove libmkxpz-core.a matches the engine \
sources. Rebuild with: cd ios/Dependencies && make -f ${PLATFORM}.make mkxp-core. \
Set EMPO_ALLOW_UNSTAMPED=1 to bypass."
fi

echo "OK: $PLATFORM native dependency artifacts look healthy"
