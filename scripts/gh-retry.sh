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
# macOS has no timeout command, so perl sets the limit. The alarm
# survives exec and kills gh with SIGALRM: exit status 142.

attempts=3
seconds=${GH_RETRY_SECONDS:-180}

attempt=1
while :; do
    perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$seconds" gh "$@"
    status=$?
    # Other failures, such as a release that does not exist, do not
    # get a retry.
    [ "$status" -eq 142 ] || exit "$status"
    [ "$attempt" -lt "$attempts" ] || break
    printf 'gh-retry: gh %s stalled for %ss, try %s of %s\n' \
        "$1" "$seconds" "$((attempt + 1))" "$attempts" >&2
    attempt=$((attempt + 1))
done

printf 'gh-retry: gh %s stalled %s times\n' "$1" "$attempts" >&2
exit 142
