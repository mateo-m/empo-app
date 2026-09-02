#!/bin/sh
# Print one sha256 for every committed input of the dependency half of
# a native tree (everything in build-<sdk>-arm64 except the engine
# outputs). The full rebuild scripts stamp it into <libdir>/.deps-fingerprint.
# scripts/rebuild-engine-halves.sh reuses a tree only when the stamp
# equals the value for the checkout.
#
# The hash reads git objects, never the working tree. Patches modify
# the checked-out sources, and `git archive` of the top repo skipped
# a nested submodule once and hashed a wrong tree without an error.
#
# Usage:
#   tools/deps-fingerprint.sh                 print the hash
#   tools/deps-fingerprint.sh --list          print the hashed lines
#   tools/deps-fingerprint.sh --require-clean fail when an input has local changes
set -eu

LIST=0
REQUIRE_CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --list) LIST=1 ;;
        --require-clean) REQUIRE_CLEAN=1 ;;
        *)
            echo "usage: $0 [--list] [--require-clean]" >&2
            exit 2
            ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DEPS=ios/Dependencies

# Submodules hash as their gitlink commit. Directories hash every
# tracked file under them. Add a path here when a new file starts to
# feed a dependency build.
INPUTS="
$DEPS/sources/sdl2
$DEPS/sources/sdl2_image
$DEPS/sources/sdl_sound
$DEPS/sources/sdl2_ttf
$DEPS/sources/freetype
$DEPS/sources/ruby
$DEPS/sources/ruby18
$DEPS/sources/ruby19
$DEPS/sources/openal-soft
$DEPS/common.make
$DEPS/iphoneos.make
$DEPS/iphonesimulator.make
$DEPS/ruby18.patches.lst
$DEPS/ruby19.patches.lst
$DEPS/ruby31.patches.lst
$DEPS/sdl2.patches.lst
$DEPS/apply-ruby-patches.sh
$DEPS/apply-sdl-patches.sh
$DEPS/pixman
$DEPS/ruby18
$DEPS/ruby19
$DEPS/ruby31
$DEPS/sdl2
$DEPS/sdl2_image
$DEPS/sdl2_ttf
$DEPS/sdl_sound
scripts/rebuild-device-deps.sh
scripts/rebuild-simulator-deps.sh
tools/deps-fingerprint.sh
"

for path in $INPUTS; do
    if ! git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
        echo "deps-fingerprint: $path is not tracked; refusing" >&2
        exit 1
    fi
done

if [ "$REQUIRE_CLEAN" = 1 ]; then
    # Modified files inside a submodule do not count. The dependency
    # rules run `git checkout -- .` before they apply patches, so a
    # previous build always leaves them modified. A submodule whose
    # HEAD is not the gitlink does count: it builds a tree the hash
    # does not describe. An uninitialized submodule passes here and
    # fails in the full build instead. The engine-only path never
    # reads it.
    # shellcheck disable=SC2086
    if ! git diff --quiet --ignore-submodules=dirty HEAD -- $INPUTS; then
        echo "deps-fingerprint: inputs have local changes; refusing" >&2
        # shellcheck disable=SC2086
        git status --short --ignore-submodules=dirty -- $INPUTS >&2
        exit 1
    fi
fi

# shellcheck disable=SC2086
LINES="$(git ls-files -s -- $INPUTS | awk '{print $4 "\t" $2}' | LC_ALL=C sort)"

if [ "$LIST" = 1 ]; then
    printf '%s\n' "$LINES"
    exit 0
fi

printf '%s\n' "$LINES" | shasum -a 256 | awk '{print $1}'
