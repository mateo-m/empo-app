#!/bin/sh
# Run a gh command, stop it after GH_RETRY_SECONDS, and try it again.
#
# Usage:
#   scripts/gh-retry.sh release download <tag> --repo <repo> --clobber ...
#
# A GitHub API call or release download can stall with no error and
# no end. In CI one stalled for 17 minutes. A download that you retry
# must overwrite its partial file, so pass --clobber.
#
# macOS has no timeout command unless Homebrew coreutils is installed.
# Without it, the command runs once with no time limit.

attempts=3
seconds=${GH_RETRY_SECONDS:-180}

if ! command -v timeout >/dev/null 2>&1; then
    exec gh "$@"
fi

attempt=1
while :; do
    timeout "$seconds" gh "$@"
    status=$?
    # timeout exits 124 when it stopped the command. Other failures,
    # such as a release that does not exist, do not get a retry.
    [ "$status" -eq 124 ] || exit "$status"
    [ "$attempt" -lt "$attempts" ] || break
    printf 'gh-retry: gh %s stalled for %ss, try %s of %s\n' \
        "$1" "$seconds" "$((attempt + 1))" "$attempts" >&2
    attempt=$((attempt + 1))
done

printf 'gh-retry: gh %s stalled %s times\n' "$1" "$attempts" >&2
exit 124
