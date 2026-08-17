#!/bin/sh
# Print a single content fingerprint (sha256) of every source that
# compiles into the mkxp{18,19,31}-merged.o binding objects:
#
#   - mkxp-z-apple-mobile/binding/*.{cpp,h}
#   - mkxp-z-apple-mobile/hmode7/src/*.{cpp,h}
#   - mkxp-z-apple-mobile/src/**/*.h   (headers the binding includes,
#     a layout change here must rebuild the merged objects or the
#     Xcode-compiled engine half sees a different ABI)
#   - ios/Dependencies/multiruby/wrapper.cpp
#
# common.make writes this value to <libdir>/.mkxp-binding-fingerprint
# after each merged.o build. scripts/verify-native-deps.sh recomputes
# it per build and fails when the merged objects are stale. Paths are
# hashed relative to their tree root so the fingerprint is identical
# across machines (prebuilt tarballs must verify on fresh clones).
set -eu

DEPS="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$(cd "$DEPS/../../mkxp-z-apple-mobile" && pwd)"

list_sources() {
    cd "$ENGINE"
    {
        find binding hmode7/src -type f \( -name '*.cpp' -o -name '*.h' \) -print
        find src -type f -name '*.h' -print
    } | LC_ALL=C sort
}

# Guard against silently hashing an empty list (e.g. a broken path
# would otherwise yield the well-known empty-input sha256).
COUNT="$(list_sources | wc -l | tr -d ' ')"
if [ "$COUNT" -lt 10 ]; then
    echo "binding-fingerprint: only $COUNT sources found under $ENGINE; refusing" >&2
    exit 1
fi

{
    (cd "$ENGINE" && list_sources | xargs shasum -a 256)
    (cd "$DEPS" && shasum -a 256 multiruby/wrapper.cpp)
} | shasum -a 256 | awk '{print $1}'
