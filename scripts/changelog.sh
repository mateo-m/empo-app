#!/usr/bin/env bash
# Prepend the CHANGELOG.md section of one version.
#
# A core update reaches this repo as one commit that changes
# cores/<core>/.version. The changes that players see are the core's
# own commits, so the section also lists the fix, feat and perf
# commits of the core between the pin at the last release and the pin
# now, in place of the update commit.
#
# Usage: scripts/changelog.sh <version>
set -euo pipefail

VERSION="${1:?usage: $0 <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Empty before the first release.
LAST_TAG="$(git describe --tags --abbrev=0 --match 'v*.*.*' HEAD 2>/dev/null || true)"

core_commits() {
    local pin var old new core repo
    [[ -n "$LAST_TAG" ]] || return 0
    for pin in cores/*/.version; do
        var="$(sed -n 's/^\([A-Z0-9_]*_CORE_VERSION\)=.*/\1/p' "$pin")"
        new="$(sed -n "s/^$var=//p" "$pin")"
        old="$(git show "$LAST_TAG:$pin" 2>/dev/null | sed -n "s/^$var=//p")"
        [[ -n "$old" && "$old" != "$new" ]] || continue
        core="$(basename "$(dirname "$pin")")"
        repo="$(sed -n 's/^CORE_REPO=//p' "cores/$core/fetch.sh")"
        # "(#58)" in a core's title is a PR of the core's repo.
        # git-cliff reads a context commit only when it has all of these fields.
        gh api "repos/$repo/compare/$old...$new" | jq -c --arg core "$core" --arg repo "$repo" '
            {username: null, pr_title: null, pr_number: null, pr_labels: [], is_first_time: false} as $remote
            | .commits[]
            | (.commit.message | split("\n")[0]
               | capture("^(?<type>fix|feat|perf)(\\([^)]*\\))?!?: (?<text>.*)$")) as $c
            | {id: .sha,
               message: ($c.text | sub(" \\(#(?<n>[0-9]+)\\)$"; " (\($repo)#\(.n))")),
               group: {fix: "Bug Fixes", feat: "Features", perf: "Performance"}[$c.type],
               extra: {core: $core, repo: $repo},
               links: [], footers: [], breaking: false, conventional: true, merge_commit: false,
               author: (.commit.author | {name, email, timestamp: (.date | fromdate)}),
               committer: (.commit.committer | {name, email, timestamp: (.date | fromdate)}),
               github: $remote, gitlab: $remote, gitea: $remote, bitbucket: $remote,
               azure_devops: $remote, remote: $remote}' || return
    done
}

CORE="$(core_commits | jq -s .)"
CONTEXT="$(mktemp)"
trap 'rm -f "$CONTEXT"' EXIT
git-cliff --config cliff.toml --unreleased --tag "v$VERSION" --context |
    jq --argjson core "$CORE" '
        ($core | map(.extra.core)) as $listed
        | .[0].commits |= map(select(.scope as $s
            | (.raw_message | test("^chore\\([a-z]+\\): use ")) and ($listed | index($s)) | not))
        | .[0].commits += $core' >"$CONTEXT"
if [[ -f CHANGELOG.md ]]; then
    git-cliff --config cliff.toml --unreleased --from-context "$CONTEXT" --prepend CHANGELOG.md
else
    git-cliff --config cliff.toml --unreleased --from-context "$CONTEXT" --output CHANGELOG.md
fi
perl -0pi -e 's/\n{3,}/\n\n/g' CHANGELOG.md
