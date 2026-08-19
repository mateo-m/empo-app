#!/bin/sh
# Run every Swift package test suite, and check the test count.
#
# Usage:
#   scripts/run-swift-tests.sh
#   scripts/run-swift-tests.sh ios/GameProbe
#   EMPO_TESTS_NO_SKIP=1 scripts/run-swift-tests.sh
#
# With no argument it runs every package. Name one or more package
# directories to run a subset.
#
# "swift test" exits 0 when it runs no test at all, so a package that
# stops building its test target reports a clean run. Each package
# below carries a floor: the run fails when the suite lists fewer
# tests than the floor. Raise a floor when you add tests. Lower one
# only on purpose, in the same commit that removes the tests.
#
# EMPO_TESTS_NO_SKIP=1 turns every host-capability skip into a
# failure. See ios/GameProbe/Tests/SkipPolicy.swift. Set it on a host
# that has the legacy text encodings and the engine submodule, which
# means macOS. The Linux runner has neither.

set -e

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

# package directory, floor
ALL_PACKAGES="ios/GameProbe:676 ios/Json5:21"

die() {
    printf 'run-swift-tests: %s\n' "$1" >&2
    exit 1
}

if [ "$#" -eq 0 ]; then
    PACKAGES="$ALL_PACKAGES"
else
    PACKAGES=""
    for wanted in "$@"; do
        match=""
        for entry in $ALL_PACKAGES; do
            [ "${entry%:*}" = "$wanted" ] && match="$entry"
        done
        [ -n "$match" ] || die "unknown package: $wanted"
        PACKAGES="$PACKAGES $match"
    done
fi

for entry in $PACKAGES; do
    dir="${entry%:*}"
    floor="${entry##*:}"
    printf '==> %s\n' "$dir"

    listed=$(cd "$dir" && swift test --list-tests | grep -c '/') ||
        die "$dir: could not list the tests"
    if [ "$listed" -lt "$floor" ]; then
        die "$dir lists $listed tests, expected at least $floor.
  Tests went missing. Add them back, or lower the floor on purpose."
    fi

    (cd "$dir" && swift test --parallel) || die "$dir: the suite failed"
    printf '%s: %s tests passed\n' "$dir" "$listed"
done
