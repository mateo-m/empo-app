#!/bin/sh
set -e

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

SUBMODULE_PATH="mkxp-z-apple-mobile"
SUBMODULE_NAME="mkxp-z-apple-mobile"
SUBMODULE_BRANCH=$(git config -f .gitmodules --get "submodule.${SUBMODULE_NAME}.branch" || printf 'dev')

if [ ! -d "$SUBMODULE_PATH/.git" ] && [ ! -f "$SUBMODULE_PATH/.git" ]; then
    printf 'pre-push failed: submodule %s is not initialized\n' "$SUBMODULE_PATH" >&2
    exit 1
fi

git -C "$SUBMODULE_PATH" fetch origin "$SUBMODULE_BRANCH" >/dev/null 2>&1

if ! git -C "$SUBMODULE_PATH" diff --quiet || ! git -C "$SUBMODULE_PATH" diff --cached --quiet; then
    printf 'pre-push failed: submodule %s has uncommitted changes\n' "$SUBMODULE_PATH" >&2
    exit 1
fi

if ! git -C "$SUBMODULE_PATH" symbolic-ref -q HEAD >/dev/null; then
    printf 'pre-push failed: submodule %s is on detached HEAD\n' "$SUBMODULE_PATH" >&2
    exit 1
fi

SUBMODULE_SHA=$(git ls-tree HEAD "$SUBMODULE_PATH" | while read -r _ _ sha _; do
    printf '%s' "$sha"
done)

if [ -z "$SUBMODULE_SHA" ]; then
    printf 'pre-push failed: could not resolve committed gitlink for %s\n' "$SUBMODULE_PATH" >&2
    exit 1
fi

CHECKED_OUT_SHA=$(git -C "$SUBMODULE_PATH" rev-parse HEAD)
if [ "$CHECKED_OUT_SHA" != "$SUBMODULE_SHA" ]; then
    printf 'pre-push failed: submodule %s checkout (%s) does not match committed pointer (%s)\n' \
        "$SUBMODULE_PATH" "$CHECKED_OUT_SHA" "$SUBMODULE_SHA" >&2
    exit 1
fi

if ! git -C "$SUBMODULE_PATH" merge-base --is-ancestor "$SUBMODULE_SHA" "origin/$SUBMODULE_BRANCH"; then
    printf 'pre-push failed: %s HEAD %s is not reachable from origin/%s\n' \
        "$SUBMODULE_PATH" "$SUBMODULE_SHA" "$SUBMODULE_BRANCH" >&2
    printf 'Push or merge the submodule branch first, then push the parent repo.\n' >&2
    exit 1
fi

if ! command -v bundle >/dev/null 2>&1; then
    printf 'pre-push failed: bundle is required to lint %s compat scripts\n' "$SUBMODULE_PATH" >&2
    exit 1
fi

printf '\n-> mkxp-z rubocop (scripts/preload, scripts/postload)\n'
if ! (cd "$SUBMODULE_PATH" && bundle exec rubocop scripts/preload scripts/postload); then
    printf 'pre-push failed: mkxp-z rubocop failed\n' >&2
    exit 1
fi

printf 'pre-push OK\n'
