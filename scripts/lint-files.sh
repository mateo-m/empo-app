#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Prints the tracked files that one lint tool checks, one on each line.
# CI and the pre-commit hook both read this list.
#
# Usage: scripts/lint-files.sh <swift-format | swiftlint | clang-format | shell>
set -euo pipefail

cd "$(dirname "$0")/.."

TOOL="${1:-}"
case "$TOOL" in
    swift-format | swiftlint) PATTERNS=('*.swift') ;;
    clang-format) PATTERNS=('*.h' '*.m' '*.mm' '*.c' '*.cpp' '*.hpp') ;;
    shell) PATTERNS=('*.sh') ;;
    *)
        echo "usage: $0 <swift-format | swiftlint | clang-format | shell>" >&2
        exit 1
        ;;
esac

# Third-party code keeps the format of its project.
VENDORED='^ios/Empo/vendor/|^ios/Json5/Sources/json5cpp/json5pp\.hpp$'
PENDING=$(sed -n "s/^$TOOL //p" scripts/lint-pending.txt)
while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    if ! git ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
        echo "error: scripts/lint-pending.txt names $file, which git does not track" >&2
        exit 1
    fi
done <<<"$PENDING"

FILES=$(git ls-files "${PATTERNS[@]}")
printf '%s\n' "$FILES" |
    grep -v -E "$VENDORED" |
    grep -v -x -F -e "${PENDING:-/}" || true
