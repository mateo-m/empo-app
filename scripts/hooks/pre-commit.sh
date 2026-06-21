#!/bin/sh
# Pre-commit hook: format staged files, then lint / verify formatting.

set -e

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

STAGED=$(git diff --cached --name-only --diff-filter=ACMR)

if [ -z "$STAGED" ]; then
    exit 0
fi

match() {
    printf '%s\n' "$STAGED" | grep -E "$1" || true
}

restage() {
    [ -z "$1" ] && return 0
    printf '%s\n' "$1" | xargs git add
}

section() {
    printf '\n-> %s\n' "$1"
}

die() {
    printf '\npre-commit failed: %s\n' "$1" >&2
    exit 1
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"
}

verify_clang_format() {
    [ -z "$1" ] && return 0
    printf '%s\n' "$1" | while IFS= read -r file; do
        [ -z "$file" ] && continue
        clang-format --dry-run --Werror "$file" ||
            die "clang-format check failed for $file"
    done
}

SWIFT_FILES=$(match '^ios/Empo/.*\.swift$')
if [ -n "$SWIFT_FILES" ]; then
    section "swift-format (Swift)"
    require_tool swift-format
    printf '%s\n' "$SWIFT_FILES" | xargs swift-format format -i
    restage "$SWIFT_FILES"
    printf '%s\n' "$SWIFT_FILES" | xargs swift-format lint --strict ||
        die "swift-format lint failed"

    section "swiftlint (Swift)"
    require_tool swiftlint
    # shellcheck disable=SC2086
    swiftlint lint --strict --quiet $SWIFT_FILES ||
        die "swiftlint failed"
fi

CPP_FILES=$(match '^ios/Empo/(src|shims)/.*\.(h|m|mm|c|cpp)$')
if [ -n "$CPP_FILES" ]; then
    section "clang-format (ObjC / C / C++)"
    require_tool clang-format
    printf '%s\n' "$CPP_FILES" | xargs clang-format -i
    restage "$CPP_FILES"
    verify_clang_format "$CPP_FILES"
fi

SH_FILES=$(match '^(setup\.sh|tools/.*\.sh|scripts/.*\.sh)$')
if [ -n "$SH_FILES" ]; then
    section "shfmt (Shell)"
    require_tool shfmt
    printf '%s\n' "$SH_FILES" | xargs shfmt -w -i 4 -ci
    restage "$SH_FILES"
    printf '%s\n' "$SH_FILES" | xargs shfmt -d -i 4 -ci ||
        die "shfmt check failed"

    section "shellcheck (Shell)"
    require_tool shellcheck
    printf '%s\n' "$SH_FILES" | xargs shellcheck ||
        die "shellcheck failed"
fi

OXFMT_FILES=$(match '^(altstore-source\.json|ios/Empo/project\.yml|ios/Empo/curated-patches/gameRegistry\.json)$')
if [ -n "$OXFMT_FILES" ]; then
    section "oxfmt (YAML / JSON)"
    require_tool bun
    printf '%s\n' "$OXFMT_FILES" | xargs bun x oxfmt
    restage "$OXFMT_FILES"
    printf '%s\n' "$OXFMT_FILES" | xargs bun x oxfmt --check ||
        die "oxfmt check failed"
fi

MD_FILES=$(match '\.md$')
if [ -n "$MD_FILES" ]; then
    section "markdownlint (Markdown)"
    require_tool bun
    printf '%s\n' "$MD_FILES" | xargs bun x markdownlint -c .markdownlint.json ||
        die "markdownlint failed"
fi

printf '\npre-commit OK\n'
